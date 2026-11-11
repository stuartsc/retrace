import AudioToolbox
import Foundation
let path=URL(fileURLWithPath:CommandLine.arguments[1])
let handle=try FileHandle(forUpdating:path)
try handle.close()
let attributes=try FileManager.default.attributesOfItem(atPath:path.path)
print("filesystem_update_open_ok true mode \(attributes[.posixPermissions] ?? "unknown")")
for permission in [AudioFilePermissions.readWritePermission,.writePermission,.readPermission] {
 var file:AudioFileID?
 let status=AudioFileOpenURL(path as CFURL,permission,0,&file)
 print("native_open_permission \(permission.rawValue) status \(status)")
 if status==noErr, let file {
  var flag:UInt32=0
  var size=UInt32(MemoryLayout<UInt32>.size)
  print("is_optimized_get_status \(AudioFileGetProperty(file,kAudioFilePropertyIsOptimized,&size,&flag)) value \(flag)")
  print("native_optimize_status \(AudioFileOptimize(file))")
  print("native_close_status \(AudioFileClose(file))")
 }
}
