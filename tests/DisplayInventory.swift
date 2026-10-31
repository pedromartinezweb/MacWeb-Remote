import CoreGraphics
import Foundation
var ids = [CGDirectDisplayID](repeating:0,count:32)
var count: UInt32 = 0
let result = CGGetOnlineDisplayList(32,&ids,&count)
let rows = ids.prefix(Int(count)).map { id -> [String:Any] in
    let bounds = CGDisplayBounds(id)
    return ["id":id,"active":CGDisplayIsActive(id) != 0,"x":bounds.minX,"y":bounds.minY,"width":bounds.width,"height":bounds.height]
}
let pointer = CGEvent(source:nil)?.location ?? .zero
let data = try JSONSerialization.data(withJSONObject:["error":result.rawValue,"displays":rows,"cursor":["x":pointer.x,"y":pointer.y]],options:[.sortedKeys])
print(String(data:data,encoding:.utf8)!)
