import Foundation
import Vision
import ImageIO
import Darwin

func historyRecognizeFrame(_ bytes:UnsafePointer<UInt8>?,_ length:UInt,_ timestamp:Double) -> UnsafeMutablePointer<CChar>? {
    autoreleasepool {
        guard let bytes,length>0,length<=8*1024*1024 else { return nil }
        let data=Data(bytes:bytes,count:Int(length))
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),
            let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1536,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
        let request=VNRecognizeTextRequest();request.recognitionLevel = .fast;request.usesLanguageCorrection=false
        request.automaticallyDetectsLanguage=false;request.recognitionLanguages=["en-US"]
        do {
            try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
            let rows=(request.results ?? []).filter { $0.boundingBox.midY<0.955 && $0.boundingBox.midY>0.045 }.sorted {
                let a=Int(($0.boundingBox.midY/0.008).rounded()),b=Int(($1.boundingBox.midY/0.008).rounded())
                if a != b {return a>b}
                return $0.boundingBox.minX<$1.boundingBox.minX
            }
            var text:[String]=[];var used=0;var seen=Set<String>()
            for row in rows {
                guard let candidate=row.topCandidates(1).first,candidate.confidence>=0.4 else { continue }
                let line=candidate.string.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
                guard !line.isEmpty,line.contains(where:{$0.isLetter}),seen.insert(line).inserted,used<2048 else { continue }
                let bounded=MemoryText.bounded(line,bytes:2048-used);used+=bounded.utf8.count;text.append(bounded)
                if text.count>=40 { break }
            }
            let value:[String:Any]=["text":text,"timestamp":timestamp,"source":"OCR","partial":true,"width":image.width,"height":image.height]
            guard let json=try? JSONSerialization.data(withJSONObject:value),let string=String(data:json,encoding:.utf8) else { return nil }
            return strdup(string)
        } catch { return nil }
    }
}
