import AppKit
import Foundation

let folder = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
let sizes = [("20", "2x", 40),("20", "3x", 60),("29", "2x", 58),("29", "3x", 87),("40", "2x", 80),("40", "3x", 120),("60", "2x", 120),("60", "3x", 180),("1024", "1x", 1024)]
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat=1) -> NSColor { NSColor(calibratedRed:r,green:g,blue:b,alpha:a) }
// The history glyph itself is glass, floating directly over the gradient.
func glassGlyph() {
    let ctx = NSGraphicsContext.current!.cgContext
    var glyph: CGPath = CGMutablePath()
    for (path,width) in markPaths() {
        let outline = width.map { path.copy(strokingWithWidth:$0,lineCap:.round,lineJoin:.round,miterLimit:10) } ?? path
        glyph = glyph.union(outline)
    }
    // A soft cast shadow separates transparent glass from the colored surface.
    ctx.saveGState()
    ctx.setShadow(offset:CGSize(width:0,height:-13),blur:17,color:color(0.08,0.13,0.35,0.35).cgColor)
    ctx.addPath(glyph);ctx.setFillColor(color(0.91,0.98,1,0.20).cgColor);ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState();ctx.addPath(glyph);ctx.clip()
    NSGradient(colorsAndLocations:(color(0.64,0.81,1,0.20),0),
        (color(0.96,0.99,1,0.42),0.48),(color(0.91,0.96,1,0.24),1))!.draw(
            in:NSRect(x:160,y:160,width:710,height:710),angle:65)
    NSGradient(starting:color(1,1,1,0.35),ending:color(1,1,1,0))!.draw(
        fromCenter:NSPoint(x:240,y:810),radius:0,toCenter:NSPoint(x:240,y:810),radius:570,options:[.drawsAfterEndingLocation])
    ctx.restoreGState()
    // Opposed inset lips give the mark thickness without an enclosing plate.
    ctx.saveGState();ctx.addPath(glyph);ctx.clip()
    ctx.translateBy(x:2,y:5);ctx.addPath(glyph);ctx.setStrokeColor(color(0.18,0.32,0.64,0.48).cgColor)
    ctx.setLineWidth(10);ctx.strokePath();ctx.restoreGState()
    ctx.saveGState();ctx.addPath(glyph);ctx.clip()
    ctx.translateBy(x:-2,y:-4);ctx.addPath(glyph);ctx.setStrokeColor(color(1,1,1,0.92).cgColor)
    ctx.setLineWidth(9);ctx.strokePath();ctx.restoreGState()
    ctx.saveGState();ctx.addPath(glyph);ctx.setStrokeColor(color(0.97,1,1,0.50).cgColor)
    ctx.setLineWidth(1.8);ctx.strokePath();ctx.restoreGState()
}
func markPaths() -> [(CGPath,CGFloat?)] {
    let ring=CGMutablePath();ring.addArc(center:CGPoint(x:512,y:512),radius:284,startAngle:135 * .pi/180,endAngle:-140 * .pi/180,clockwise:true)
    var result:[(CGPath,CGFloat?)]=[(ring,58)]
    let arrow=CGMutablePath();arrow.move(to:CGPoint(x:260,y:642));arrow.addLine(to:CGPoint(x:396,y:713));arrow.addQuadCurve(to:CGPoint(x:399,y:732),control:CGPoint(x:413,y:719));arrow.addLine(to:CGPoint(x:315,y:803));arrow.addQuadCurve(to:CGPoint(x:297,y:794),control:CGPoint(x:299,y:811));arrow.closeSubpath();result.append((arrow,nil))
    for (y,width) in [(CGFloat(608),CGFloat(245)),(CGFloat(490),CGFloat(207)),(CGFloat(372),CGFloat(164))] {
        result.append((CGPath(roundedRect:CGRect(x:401,y:y,width:width,height:43),cornerWidth:21.5,cornerHeight:21.5,transform:nil),nil))
    }
    return result
}
var images = [[String:String]]()
for (points,scale,size) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let transform=NSAffineTransform();transform.scale(by:CGFloat(size)/1024);transform.concat()
    let canvas=NSRect(x:0,y:0,width:1024,height:1024)
    NSGradient(colorsAndLocations:(color(0.30,0.73,0.87),0),(color(0.32,0.46,0.87),0.48),(color(0.53,0.36,0.83),1))!.draw(in:canvas,angle:35)
    NSGradient(starting:color(0.89,0.98,1,0.40),ending:color(0.89,0.98,1,0))!.draw(fromCenter:NSPoint(x:170,y:880),radius:0,toCenter:NSPoint(x:170,y:880),radius:850,options:[.drawsAfterEndingLocation])
    glassGlyph()
    NSGraphicsContext.restoreGraphicsState()
    let filename="icon-\(points)-\(scale).png"
    let opaque = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    for y in 0..<size { for x in 0..<size {
        let source=bitmap.bitmapData!+y*bitmap.bytesPerRow+x*4
        let dest=opaque.bitmapData!+y*opaque.bytesPerRow+x*3
        dest[0]=source[0];dest[1]=source[1];dest[2]=source[2]
    }}
    try opaque.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(filename))
    images.append(["idiom":size == 1024 ? "ios-marketing":"iphone","size":"\(points)x\(points)","scale":scale,"filename":filename])
}
try JSONSerialization.data(withJSONObject:["images":images,"info":["version":1,"author":"xcode"]],options:.prettyPrinted).write(to:folder.appendingPathComponent("Contents.json"))
let logo=folder.deletingLastPathComponent().appendingPathComponent("HistoryLogo.imageset",isDirectory:true)
try FileManager.default.createDirectory(at:logo,withIntermediateDirectories:true)
try Data(contentsOf:folder.appendingPathComponent("icon-1024-1x.png")).write(to:logo.appendingPathComponent("logo.png"))
try JSONSerialization.data(withJSONObject:["images":[["idiom":"universal","filename":"logo.png"]],"info":["version":1,"author":"xcode"]],options:.prettyPrinted).write(to:logo.appendingPathComponent("Contents.json"))

func svgPath(_ path:CGPath) -> String {
    var d=""
    func number(_ n:CGFloat) -> String { String(format:"%.3f",Double(n)) }
    path.applyWithBlock { pointer in
        let e=pointer.pointee;let p=e.points
        switch e.type {
        case .moveToPoint:d+="M\(number(p[0].x)) \(number(p[0].y))"
        case .addLineToPoint:d+="L\(number(p[0].x)) \(number(p[0].y))"
        case .addQuadCurveToPoint:d+="Q\(number(p[0].x)) \(number(p[0].y)) \(number(p[1].x)) \(number(p[1].y))"
        case .addCurveToPoint:d+="C\(number(p[0].x)) \(number(p[0].y)) \(number(p[1].x)) \(number(p[1].y)) \(number(p[2].x)) \(number(p[2].y))"
        case .closeSubpath:d+="Z"
        @unknown default:break
        }
    }
    return d
}
// Symbols use cap-height guides, rather than the app icon's full canvas.
// Let the circular mark extend above/below that cap height, like system circle
// symbols, so it stays readable at the Control Center's small icon size.
var symbolGlyph:CGPath = CGMutablePath()
for (path,width) in markPaths() {
    let outline=width.map { path.copy(strokingWithWidth:$0,lineCap:.round,lineJoin:.round,miterLimit:10) } ?? path
    symbolGlyph=symbolGlyph.union(outline)
}
var symbolTransform=CGAffineTransform(a:1.5,b:0,c:0,d:-1.5,tx:-436,ty:1125.5)
let paths="<path fill=\"black\" d=\"\(svgPath(symbolGlyph.copy(using:&symbolTransform)!))\"/>"
let symbol="""
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 3300 2700">
<g id="Notes"><text id="template-version" x="0" y="0">Template v.3.0</text></g>
<g id="Guides">
<line id="Baseline-S" x1="0" y1="500" x2="3300" y2="500"/><line id="Capline-S" x1="0" y1="0" x2="3300" y2="0"/>
<line id="Baseline-M" x1="0" y1="1300" x2="3300" y2="1300"/><line id="Capline-M" x1="0" y1="600" x2="3300" y2="600"/>
<line id="Baseline-L" x1="0" y1="2150" x2="3300" y2="2150"/><line id="Capline-L" x1="0" y1="1400" x2="3300" y2="1400"/>
<line id="left-margin-Regular-M" x1="850" y1="0" x2="1000" y2="2200"/><line id="right-margin-Regular-M" x1="1850" y1="0" x2="1700" y2="2200"/>
</g><g id="Symbols"><g id="Regular-S" transform="translate(1000 0) scale(0.714285714)">\(paths)</g><g id="Regular-M" transform="translate(1000 600)">\(paths)</g><g id="Regular-L" transform="translate(1000 1400) scale(1.071428571)">\(paths)</g></g></svg>
"""
let assets=folder.deletingLastPathComponent()
let base=assets.deletingLastPathComponent().deletingLastPathComponent()
for directory in [assets.appendingPathComponent("HistoryControlMark.symbolset"),base.appendingPathComponent("Controls/Assets.xcassets/HistoryControlMark.symbolset")] {
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    try symbol.write(to:directory.appendingPathComponent("mark.svg"),atomically:true,encoding:.utf8)
    try "{\"properties\":{\"symbol-rendering-intent\":\"template\"},\"symbols\":[{\"idiom\":\"universal\",\"filename\":\"mark.svg\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}".write(to:directory.appendingPathComponent("Contents.json"),atomically:true,encoding:.utf8)
}
