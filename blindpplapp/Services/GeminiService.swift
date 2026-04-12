import Combine
import Foundation
import os

// MARK: - Gemini 2.0 Flash API client for scene reasoning and navigation guidance

@MainActor
final class GeminiService: ObservableObject {

 // MARK: - State

 @Published private(set) var isProcessing = false
 @Published private(set) var lastResponseTime: Date?
 @Published private(set) var lastError: String?

 // MARK: - Private

 private var apiKey: String = ""
 private let session = URLSession(configuration: .default)

 // Allowed YOLOE class labels — must match NAVIGATION_CLASSES in export_yoloe_coreml.py
 static let navigationClasses = [
  "door", "doorway", "exit sign", "entrance",
  "elevator", "escalator", "stairs", "staircase",
  "hallway", "corridor",
  "chair", "table", "desk", "bench", "couch",
  "trash can", "recycling bin",
  "vending machine", "water fountain",
  "sign", "room number", "restroom sign",
  "fire extinguisher", "emergency exit",
  "handrail", "ramp",
  "person", "wheelchair", "cart", "luggage",
  "pillar", "column", "wall",
  "restroom", "bathroom", "toilet",
  "window", "clock", "light", "plant", "potted plant",
 ]

 // Rate limiting state
 private var retryAfterDate: Date?
 private var consecutiveErrors = 0
 private let maxConsecutiveErrors = 3

 // Gemini 2.5 Flash (stable) — higher free-tier quota than preview models
 // See: https://ai.google.dev/gemini-api/docs/models/gemini
 private var endpoint: URL {
  URL(
   string:
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)"
  )!
 }

 // MARK: - Configuration

 func configure(apiKey: String) {
  self.apiKey = apiKey
  BNLog.gemini.info("Gemini service configured with API key (length: \(apiKey.count))")
 }

 // MARK: - Navigation reasoning request

 /// Sends the current scene to Gemini and asks for the next secondary goal.
 /// - Parameters:
 ///   - imageData: JPEG-compressed camera frame
 ///   - destination: The user's final destination (e.g., "bathroom")
 ///   - completedGoals: List of previously completed secondary goals
 ///   - currentGoalStatus: Description of what happened with the current secondary goal
 enum GeminiFailureReason {
  case apiKeyMissing
  case rateLimited(retryAfterSeconds: Double)
  case quotaExhausted
  case networkError(String)
  case parseError
  case apiError(Int)
 }

 /// Last failure reason for better user feedback
 @Published private(set) var lastFailureReason: GeminiFailureReason?

 func requestNextGoal(
  imageData: Data,
  destination: String,
  completedGoals: [String],
  currentGoalStatus: String
 ) async -> GeminiNavigationResponse? {
  guard !apiKey.isEmpty else {
   BNLog.gemini.error("Gemini API key not set")
   await MainActor.run { lastFailureReason = .apiKeyMissing }
   return nil
  }

  if let retryAfter = retryAfterDate, Date() < retryAfter {
   let waitTime = retryAfter.timeIntervalSinceNow
   BNLog.gemini.warning(
    "Rate limited, waiting \(String(format: "%.1f", waitTime))s before retry")
   await MainActor.run { lastFailureReason = .rateLimited(retryAfterSeconds: waitTime) }
   return nil
  }

  await MainActor.run { isProcessing = true }
  defer { Task { @MainActor in isProcessing = false } }

  let systemPrompt = buildSystemPrompt()
  let userPrompt = buildUserPrompt(
   destination: destination,
   completedGoals: completedGoals,
   currentGoalStatus: currentGoalStatus
  )

  let base64Image = imageData.base64EncodedString()

  // Build the Gemini API request body
  let requestBody: [String: Any] = [
   "system_instruction": [
    "parts": [["text": systemPrompt]]
   ],
   "contents": [
    [
     "parts": [
      [
       "inline_data": [
        "mime_type": "image/jpeg",
        "data": base64Image,
       ]
      ],
      ["text": userPrompt],
     ]
    ]
   ],
   "generation_config": [
    "response_mime_type": "application/json",
    "response_schema": responseSchema(),
    "temperature": 0.3,
    "max_output_tokens": 4096,
   ],
   "safety_settings": [
    ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
   ],
  ]

  do {
   let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

   var request = URLRequest(url: endpoint)
   request.httpMethod = "POST"
   request.httpBody = jsonData
   request.setValue("application/json", forHTTPHeaderField: "Content-Type")
   request.timeoutInterval = 30

   BNLog.gemini.info("Sending navigation request to Gemini (image: \(imageData.count) bytes)")
   let startTime = CFAbsoluteTimeGetCurrent()

   let (data, response) = try await session.data(for: request)

   let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
   BNLog.gemini.info("Gemini responded in \(String(format: "%.0f", elapsed))ms")

   guard let httpResponse = response as? HTTPURLResponse else {
    BNLog.gemini.error("Non-HTTP response from Gemini")
    return nil
   }

   guard httpResponse.statusCode == 200 else {
    let errorBody = String(data: data, encoding: .utf8) ?? "no body"
    BNLog.gemini.error("Gemini API error \(httpResponse.statusCode): \(errorBody)")
    await MainActor.run { lastError = "API error: \(httpResponse.statusCode)" }

    if httpResponse.statusCode == 429 {
     consecutiveErrors += 1
     let backoffSeconds =
      parseRetryDelay(from: data)
      ?? min(pow(2.0, Double(consecutiveErrors)) * 10.0, 120.0)
     retryAfterDate = Date().addingTimeInterval(backoffSeconds)
     BNLog.gemini.warning(
      "Rate limited. Will retry after \(String(format: "%.1f", backoffSeconds))s")

     let isQuotaExhausted =
      errorBody.contains("free_tier") || errorBody.contains("RESOURCE_EXHAUSTED")
     await MainActor.run {
      lastFailureReason =
       isQuotaExhausted ? .quotaExhausted : .rateLimited(retryAfterSeconds: backoffSeconds)
     }
    } else {
     await MainActor.run { lastFailureReason = .apiError(httpResponse.statusCode) }
    }

    return nil
   }

   let parsed = try parseGeminiResponse(data)
   await MainActor.run {
    lastResponseTime = Date()
    lastError = nil
    // Reset error state on success
    self.consecutiveErrors = 0
    self.retryAfterDate = nil
   }

   BNLog.gemini.info(
    "Gemini goal: '\(parsed.secondaryGoalDescriptor)' (confidence: \(parsed.confidence))")
   BNLog.gemini.info("Gemini reasoning: \(parsed.reasoning)")
   return parsed

  } catch {
   BNLog.gemini.error("Gemini request failed: \(error.localizedDescription)")
   await MainActor.run {
    lastError = error.localizedDescription
    lastFailureReason = .networkError(error.localizedDescription)
   }
   return nil
  }
 }

 // MARK: - Voice command request

 /// Sends the current scene to Gemini along with the user's spoken question.
 /// Returns a navigation response (new waypoint) informed by what the user asked.
 func requestWithVoiceCommand(
  imageData: Data,
  command: String,
  destination: String,
  completedGoals: [String],
  currentGoalDescriptor: String?
 ) async -> GeminiNavigationResponse? {
  guard !apiKey.isEmpty else {
   BNLog.gemini.error("Gemini API key not set")
   return nil
  }

  if let retryAfter = retryAfterDate, Date() < retryAfter {
   BNLog.gemini.warning("Rate limited — skipping voice command request")
   return nil
  }

  await MainActor.run { isProcessing = true }
  defer { Task { @MainActor in isProcessing = false } }

  let systemPrompt = buildSystemPrompt()
  var userPrompt = "DESTINATION: \(destination)\n\n"

  if !completedGoals.isEmpty {
   userPrompt += "COMPLETED WAYPOINTS (already reached):\n"
   for (i, goal) in completedGoals.enumerated() {
    userPrompt += "  \(i + 1). \(goal)\n"
   }
   userPrompt += "\n"
  }

  if let current = currentGoalDescriptor {
   userPrompt += "CURRENT WAYPOINT: \(current)\n\n"
  }

  userPrompt += "THE USER JUST ASKED: \"\(command)\"\n\n"
  userPrompt += "Answer the user's question by analyzing the image. "
  userPrompt += "Provide a new or updated waypoint that addresses what they asked. "
  userPrompt += "If they're asking for directions, choose the best next object to walk toward."

  let base64Image = imageData.base64EncodedString()

  let requestBody: [String: Any] = [
   "system_instruction": [
    "parts": [["text": systemPrompt]]
   ],
   "contents": [
    [
     "parts": [
      [
       "inline_data": [
        "mime_type": "image/jpeg",
        "data": base64Image,
       ]
      ],
      ["text": userPrompt],
     ]
    ]
   ],
   "generation_config": [
    "response_mime_type": "application/json",
    "response_schema": responseSchema(),
    "temperature": 0.3,
    "max_output_tokens": 4096,
   ],
   "safety_settings": [
    ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
   ],
  ]

  do {
   let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

   var request = URLRequest(url: endpoint)
   request.httpMethod = "POST"
   request.httpBody = jsonData
   request.setValue("application/json", forHTTPHeaderField: "Content-Type")
   request.timeoutInterval = 30

   BNLog.gemini.info("Sending voice command request to Gemini: '\(command)'")
   let startTime = CFAbsoluteTimeGetCurrent()

   let (data, response) = try await session.data(for: request)

   let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
   BNLog.gemini.info("Gemini voice command responded in \(String(format: "%.0f", elapsed))ms")

   guard let httpResponse = response as? HTTPURLResponse,
    httpResponse.statusCode == 200
   else {
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
    BNLog.gemini.error("Gemini voice command error: \(statusCode)")
    if statusCode == 429 {
     consecutiveErrors += 1
     let backoff =
      parseRetryDelay(from: data)
      ?? min(pow(2.0, Double(consecutiveErrors)) * 10.0, 120.0)
     retryAfterDate = Date().addingTimeInterval(backoff)
    }
    return nil
   }

   let parsed = try parseGeminiResponse(data)
   await MainActor.run {
    lastResponseTime = Date()
    lastError = nil
    consecutiveErrors = 0
    retryAfterDate = nil
   }

   BNLog.gemini.info("Voice command goal: '\(parsed.secondaryGoalDescriptor)'")
   return parsed

  } catch {
   BNLog.gemini.error("Gemini voice command failed: \(error.localizedDescription)")
   await MainActor.run { lastError = error.localizedDescription }
   return nil
  }
 }

 // MARK: - System prompt

 private func buildSystemPrompt() -> String {
  let allowedClasses = Self.navigationClasses.joined(separator: "\", \"")
  return """
   You are a navigation assistant for a blind person navigating an indoor environment. \
   The user is holding their phone on their chest, and the camera image shows what is in front of them.

   Your job:
   1. Analyze the image to understand the indoor environment (hallway, room, lobby, etc.)
   2. Identify a specific, visible OBJECT in the image that the user should walk toward as an intermediate waypoint. You will be given a list of classes you are allowed to identify. Use more distic identifiable objects like "table", "chair", rather than "wall".
   3. This object should move the user closer to their final destination.
   4. The object descriptor MUST be one of these exact class labels (these are the only classes \
      the on-device YOLOE detector can recognize): \
      ["\(allowedClasses)"]. \
      Pick the single best-matching label from this list. Do NOT invent new labels or add adjectives/colors.
   5. Put all spatial/directional context in the direction_hint field instead, NOT in the descriptor. You MUST include directional pointers like "left", "right", or "forward" in the direction_hint field.
   6. Do NOT give vague directions like "go left" — always specify a concrete object along with the direction.
   7. If the user has already visited waypoints, try to suggest a different direction to avoid going in circles.
   8. Prioritize safety: avoid directing toward stairs, glass doors, or obstacles.
   9. CRITICALLY evaluate whether the user's FINAL DESTINATION is actually visible in the image. \
      Set destination_in_sight to true ONLY if you can clearly see the destination itself (e.g. the bathroom door, \
      the specific room entrance, the elevator). Do NOT set it to true just because the user is in the right area \
      or heading in the right direction — the destination must be unambiguously visible in the current frame.

   Respond with structured JSON only. No additional text.
   """
 }

 // MARK: - User prompt

 private func buildUserPrompt(
  destination: String,
  completedGoals: [String],
  currentGoalStatus: String
 ) -> String {
  var prompt = "DESTINATION: \(destination)\n\n"

  if !completedGoals.isEmpty {
   prompt += "COMPLETED WAYPOINTS (already reached):\n"
   for (i, goal) in completedGoals.enumerated() {
    prompt += "  \(i + 1). \(goal)\n"
   }
   prompt += "\n"
  }

  prompt += "CURRENT STATUS: \(currentGoalStatus)\n\n"
  prompt +=
   "Analyze the image and provide the next waypoint object the user should walk toward to reach '\(destination)'."

  return prompt
 }

 // MARK: - Response schema for structured output

 private func responseSchema() -> [String: Any] {
  [
   "type": "OBJECT",
   "properties": [
    "secondary_goal_descriptor": [
     "type": "STRING",
     "description":
      "Must be one of the allowed YOLOE class labels listed in the system prompt. No spatial context, no adjectives.",
     "enum": Self.navigationClasses,
    ],
    "direction_hint": [
     "type": "STRING",
     "description":
      "Spatial direction and context. MUST include directional pointers like 'left', 'right', 'forward', 'straight ahead' (e.g., 'ahead and slightly left, about 10 feet away near the wall')",
    ],
    "reasoning": [
     "type": "STRING",
     "description": "Brief explanation of why this waypoint was chosen",
    ],
    "confidence": [
     "type": "NUMBER",
     "description": "Confidence 0-1 that this waypoint moves toward the destination",
    ],
    "destination_in_sight": [
     "type": "BOOLEAN",
     "description":
      "True ONLY if the final destination is clearly and unambiguously visible in the image right now. False if unsure or if only nearby landmarks are visible.",
    ],
   ],
   "required": [
    "secondary_goal_descriptor",
    "direction_hint",
    "reasoning",
    "confidence",
    "destination_in_sight",
   ],
  ]
 }

 // MARK: - Parse response

 private func parseGeminiResponse(_ data: Data) throws -> GeminiNavigationResponse {
  // Gemini wraps the response in candidates[0].content.parts[].text
  // Gemini 3 Flash (thinking model) may include thought parts before the text part,
  // so we search all parts for the last one containing a "text" key.
  guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
   let candidates = json["candidates"] as? [[String: Any]],
   let firstCandidate = candidates.first,
   let content = firstCandidate["content"] as? [String: Any],
   let parts = content["parts"] as? [[String: Any]]
  else {
   let rawBody = String(data: data, encoding: .utf8) ?? "non-utf8"
   BNLog.gemini.error("Unexpected Gemini response structure: \(rawBody.prefix(500))")
   throw GeminiError.invalidResponseStructure
  }

  // Find the last part with a "text" key (skip thought parts)
  guard let textPart = parts.last(where: { $0["text"] != nil })?["text"] as? String else {
   let partKeys = parts.map { Array($0.keys) }
   BNLog.gemini.error("No text part found in Gemini response. Part keys: \(partKeys)")
   throw GeminiError.invalidResponseStructure
  }

  BNLog.gemini.info("Gemini raw text: \(textPart.prefix(300))")

  let responseData = Data(textPart.utf8)
  let decoded = try JSONDecoder().decode(GeminiNavigationResponse.self, from: responseData)
  return decoded
 }

 // MARK: - Retry delay parsing

 /// Extracts the retry delay from a Gemini 429 response body.
 /// Looks for `"retryDelay": "33s"` in the error details.
 private func parseRetryDelay(from data: Data) -> Double? {
  guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let error = json["error"] as? [String: Any],
   let details = error["details"] as? [[String: Any]]
  else {
   return nil
  }
  for detail in details {
   if let retryDelay = detail["retryDelay"] as? String {
    // Parse "33s" or "33.5s" format
    let digits = retryDelay.replacingOccurrences(of: "s", with: "")
    if let seconds = Double(digits) {
     return seconds
    }
   }
  }
  return nil
 }

 // MARK: - Errors

 enum GeminiError: Error, LocalizedError {
  case invalidResponseStructure
  case apiKeyMissing

  var errorDescription: String? {
   switch self {
   case .invalidResponseStructure: return "Gemini returned an unexpected response format"
   case .apiKeyMissing: return "Gemini API key not configured"
   }
  }
 }
}
