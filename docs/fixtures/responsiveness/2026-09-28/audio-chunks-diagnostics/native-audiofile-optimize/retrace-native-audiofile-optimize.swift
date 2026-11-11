import AudioToolbox
import AVFoundation
import CryptoKit
import Foundation

let sourceRoot=URL(fileURLWithPath:"/tmp/retrace-audio-boundary-final-20260928-1749")
let output=URL(fileURLWithPath:"/tmp/retrace-audiofile-optimize-20260928-1801")
guard !FileManager.default.fileExists(atPath:output.path) else { fatalError("Refusing to overwrite diagnostic") }
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
struct Failure:Error { let label:String; let status:OSStatus }
func require(_ status:OSStatus,_ label:String) throws { guard status == noErr else { throw Failure(label:label,status:status) } }
func sha(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
func property<T>(_ file:AudioFileID,_ key:AudioFilePropertyID,_ initial:T) throws -> T {
 var value=initial
 var size=UInt32(MemoryLayout<T>.size)
 try require(AudioFileGetProperty(file,key,&size,&value),"get \(key)")
 return value
}
func snapshot(_ url:URL) async throws -> (json:[String:Any],pcm:[Int16]) {
 var opened:AudioFileID?
 try require(AudioFileOpenURL(url as CFURL,.readPermission,0,&opened),"open read")
 guard let file=opened else { throw Failure(label:"empty file",status:-1) }
 defer { AudioFileClose(file) }
 let format=try property(file,kAudioFilePropertyDataFormat,AudioStreamBasicDescription())
 let table=try property(file,kAudioFilePropertyPacketTableInfo,AudioFilePacketTableInfo())
 let packetCount=try property(file,kAudioFilePropertyAudioDataPacketCount,UInt64(0))
 let audioBytes=try property(file,kAudioFilePropertyAudioDataByteCount,UInt64(0))
 let offset=try property(file,kAudioFilePropertyDataOffset,Int64(0))
 let optimized=try property(file,kAudioFilePropertyIsOptimized,UInt32(0))
 guard packetCount>0,packetCount<=1024,audioBytes>0,audioBytes<=4*1024*1024 else { throw Failure(label:"bounds",status:-1) }
 var payload=[UInt8](repeating:0,count:Int(audioBytes))
 var descriptions=[AudioStreamPacketDescription](repeating:AudioStreamPacketDescription(),count:Int(packetCount))
 var bytes=UInt32(audioBytes)
 var packets=UInt32(packetCount)
 let status=AudioFileReadPacketData(file,false,&bytes,&descriptions,0,&packets,&payload)
 guard status == noErr || status == kAudioFileEndOfFileError,packets==packetCount,bytes==audioBytes else { throw Failure(label:"read packets",status:status) }
 var cookieSize:UInt32=0
 var writable:UInt32=0
 try require(AudioFileGetPropertyInfo(file,kAudioFilePropertyMagicCookieData,&cookieSize,&writable),"cookie size")
 guard cookieSize<=65536 else { throw Failure(label:"cookie bounds",status:-1) }
 var cookie=[UInt8](repeating:0,count:Int(cookieSize))
 try require(AudioFileGetProperty(file,kAudioFilePropertyMagicCookieData,&cookieSize,&cookie),"cookie")
 let native=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
 guard native.length==table.mNumberValidFrames,native.processingFormat.sampleRate==16000,native.processingFormat.channelCount==1 else { throw Failure(label:"decode format",status:-1) }
 let buffer=AVAudioPCMBuffer(pcmFormat:native.processingFormat,frameCapacity:4096)!
 var pcm:[Int16]=[]
 while pcm.count<Int(native.length) {
  try native.read(into:buffer,frameCount:AVAudioFrameCount(min(4096,Int(native.length)-pcm.count)))
  guard buffer.frameLength>0 else { throw Failure(label:"short decode",status:-1) }
  for i in 0..<Int(buffer.frameLength) {
   let sample=buffer.floatChannelData![0][i]
   guard sample.isFinite else { throw Failure(label:"nonfinite decode",status:-1) }
   pcm.append(Int16(max(-32768,min(32767,(Double(sample)*32768).rounded(.toNearestOrAwayFromZero)))))
  }
 }
 let pcmBytes=pcm.withUnsafeBytes { Data($0) }
 let tracks=try await AVURLAsset(url:url).loadTracks(withMediaType:.audio)
 guard tracks.count==1 else { throw Failure(label:"tracks",status:-1) }
 let time=try await tracks[0].load(.timeRange)
 let data=try Data(contentsOf:url)
 let json:[String:Any]=["file_bytes":data.count,"file_sha256":sha(data),"is_optimized":optimized,
  "audio_data_offset":offset,"audio_payload_bytes":audioBytes,"audio_payload_sha256":sha(Data(payload)),
  "packet_count":packetCount,"packet_sizes":descriptions.map{Int($0.mDataByteSize)},
  "packet_variable_frames":descriptions.map{Int($0.mVariableFramesInPacket)},"magic_cookie_sha256":sha(Data(cookie)),
  "format_id":format.mFormatID,"sample_rate":format.mSampleRate,"channels":format.mChannelsPerFrame,"frames_per_packet":format.mFramesPerPacket,
  "valid_frames":table.mNumberValidFrames,"priming_frames":table.mPrimingFrames,"remainder_frames":table.mRemainderFrames,
  "track_start_seconds":time.start.seconds,"track_duration_seconds":time.duration.seconds,
  "decoded_frames":pcm.count,"decoded_pcm_sha256_diagnostic":sha(pcmBytes)]
 return (json,pcm)
}
let enumerator=FileManager.default.enumerator(at:sourceRoot,includingPropertiesForKeys:nil)!
var sources:[URL]=[]
while let url=enumerator.nextObject() as? URL { if url.pathExtension=="m4a" { sources.append(url) } }
var rows:[[String:Any]]=[]
for source in sources.sorted(by:{$0.path<$1.path}) {
 let originalHash=sha(try Data(contentsOf:source))
 let destination=output.appendingPathComponent(source.lastPathComponent)
 try FileManager.default.copyItem(at:source,to:destination)
 let before=try await snapshot(destination)
 var opened:AudioFileID?
 let openStatus=AudioFileOpenURL(destination as CFURL,.readWritePermission,0,&opened)
 var optimizeStatus:OSStatus=0
 var closeStatus:OSStatus=0
 let start=ContinuousClock.now
 if openStatus==noErr,let file=opened { optimizeStatus=AudioFileOptimize(file); closeStatus=AudioFileClose(file) }
 let elapsed=start.duration(to:.now)
 let after=try await snapshot(destination)
 let originalUnchanged=sha(try Data(contentsOf:source))==originalHash
 var maximum=0,changed=0
 for (left,right) in zip(before.pcm,after.pcm) { let delta=abs(Int(left)-Int(right)); maximum=max(maximum,delta); if delta>0 {changed += 1} }
 rows.append(["source":source.path,"private_copy":destination.path,"source_unchanged":originalUnchanged,
 "open_status":openStatus,"optimize_status":optimizeStatus,"close_status":closeStatus,
 "optimize_seconds":Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18,
 "before":before.json,"after":after.json,"decoded_frames_equal":before.pcm.count==after.pcm.count,
 "max_abs_pcm16_difference":maximum,"changed_pcm16_samples":changed,
 "file_bytes_saved":(before.json["file_bytes"] as! Int)-(after.json["file_bytes"] as! Int)])
}
let report:[String:Any]=["scope":"private_copies_of_authored_AAC_only_no_application_change_or_promotion",
 "api":"AudioFileOptimize","documentation":"AudioFile.h describes append readiness, not minimum file size",
 "os":ProcessInfo.processInfo.operatingSystemVersionString,"rows":rows]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
try data.write(to:output.appendingPathComponent("optimization-comparison.json"),options:.withoutOverwriting)
print(String(decoding:data,as:UTF8.self))
