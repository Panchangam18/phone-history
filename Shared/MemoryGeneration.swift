import Foundation
import FoundationModels

@Generable
struct GeneratedMemorySupport:Sendable {
    @Guide(description:"Number of the SCREEN excerpt containing the supporting quote.",.range(1...12))
    var excerpt:Int
    @Guide(description:"Line number within that SCREEN containing the specific subject or explicit result supporting the summary. Navigation controls do not support an activity.",.range(1...40))
    var line:Int
}

@Generable
struct GeneratedMemory:Sendable {
    @Guide(description:"Notes identifying readable content subjects and explicit results, with each author associated only with their own post. Leave uncertain actions unknown.")
    var grounding:String
    @Guide(description:"Choose 1–4 SCREEN and line references containing the specific subjects or explicit results in the observations. Cite captions or titles, not navigation or account statistics. Empty if no meaningful content is supported.",.maximumCount(4))
    var support:[GeneratedMemorySupport]
    @Guide(description:"Short title naming the specific subjects of the summary. At most 160 UTF-8 bytes; empty if no meaningful activity is supported.")
    var title:String
    @Guide(description:"1–3 specific sentences about the phone owner's supported activity and its subjects, addressed as you. Preserve explicit outcomes; leave uncertain actions unknown. At most 1000 UTF-8 bytes; empty if only clutter is supported.")
    var summary:String

}

enum MemoryGeneration {
    static func generate(scope:String,excerpts:[MemoryExcerpt]) async throws -> GeneratedMemory {
        let session=LanguageModelSession(instructions:MemoryPrompts.generation)
        return try await session.respond(to:MemoryPrompts.request(scope:scope,evidence:NaturalMemory.excerptPrompt(excerpts)),
            generating:GeneratedMemory.self,options:GenerationOptions(sampling:.greedy,maximumResponseTokens:600)).content
    }
}
