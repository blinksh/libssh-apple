import Foundation
import FMake

OutputLevel.default = .error

enum Config {
  static let libsshOrigin = "https://github.com/blinksh/libssh.git"
  static let libsshBranch = "blink-libssh-0.12.0"
  static let libsshVersion = "0.12.0"
  
  static let frameworkName = "LibSSH"
  
  //static let platforms: [Platform] = Platform.allCases.filter { $0 != .Catalyst }
  static let platforms: [Platform] = [.iPhoneOS, .iPhoneSimulator]
  //static let platforms: [Platform] = [Platform.MacOSX]
}

extension Platform {
  var opensslPlatform: String {
    sdk
  }

  var deploymentTarget: String {
    switch self {
    case .AppleTVOS, .AppleTVSimulator,
         .iPhoneOS, .iPhoneSimulator: return "14.0"
    case .MacOSX, .Catalyst: return "11.0"
    case .WatchOS, .WatchSimulator: return "7.0"
    }
  }

  var ldPlatformName: String {
    switch self {
    case .MacOSX: return "macos"
    case .Catalyst: return "mac-catalyst"
    case .iPhoneOS: return "ios"
    case .iPhoneSimulator: return "ios-simulator"
    case .AppleTVOS: return "tvos"
    case .AppleTVSimulator: return "tvos-simulator"
    case .WatchOS: return "watchos"
    case .WatchSimulator: return "watchos-simulator"
    }
  }
}


try sh("git submodule update --init")

try? sh("rm -rf libssh")
try sh("git clone --depth 1 \(Config.libsshOrigin) --branch \(Config.libsshBranch)")

let fm = FileManager.default
let cwd = fm.currentDirectoryPath
let opensslRoot = "\(cwd)/openssl-kz"
let toolchain = "\(cwd)/apple.cmake"


var dynamicFrameworkPaths: [String] = []
var staticFrameworkPaths: [String] = []

// arm64e is excluded because the OpenSSL frameworks we link against
// (krzyzanowskim) don't ship an arm64e slice.
let platformBuilds: [(Platform, [Platform.Arch])] = Config.platforms.compactMap { p in
  let archs = p.archs.filter { $0 != .arm64e }
  return archs.isEmpty ? nil : (p, archs)
}

for (p, buildArchs) in platformBuilds {
  let cflags = "-fobjc-arc"
  let cppflags = "-fobjc-arc"

  var env = try [
    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
    "APPLE_PLATFORM": p.sdk,
    "APPLE_SDK_PATH": p.sdkPath(),
    "SECOND_FIND_ROOT_PATH": "\(opensslRoot)/\(p.opensslPlatform)",
    "CFLAGS": cflags,
    "CPPFLAGS": cppflags
  ]

  let frameworkDynamicPath = "frameworks/dynamic/\(p.name)/\(Config.frameworkName).framework"
  let frameworkStaticPath = "frameworks/static/\(p.name)/\(Config.frameworkName).framework"
  dynamicFrameworkPaths.append(frameworkDynamicPath)
  staticFrameworkPaths.append(frameworkStaticPath)
  
  for arch in buildArchs {

    print(env)
    
    let libPath = "lib/\(p.name)-\(arch).sdk"
    let binPath = "bin/\(p.name)-\(arch).sdk"
    
    try? sh("rm -rf \(binPath)")
    
    try? sh("rm -rf \(libPath)")
    try? mkdir(libPath)

    try sh(
      "cmake",
      "-Hlibssh -B\(binPath)",
      "-GXcode",
      "-DCMAKE_TOOLCHAIN_FILE=\(toolchain)",
      "-DCMAKE_C_COMPILER=\(p.ccPath())",
      "-DCMAKE_OSX_ARCHITECTURES=\(arch)",
      "-DCMAKE_OSX_DEPLOYMENT_TARGET=\(p.deploymentTarget)",
      "-DCMAKE_POLICY_VERSION_MINIMUM=3.16",
      "-DBUILD_SHARED_LIBS=OFF",
      "-DWITH_EXAMPLES=OFF",
      "-DWITH_EXEC=OFF",
      "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
      "-DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO",
      "-DCMAKE_SYSTEM_PROCESSOR=\(arch)",
      "-DCMAKE_INSTALL_PREFIX=\(libPath)"
      , env: env)
    
    try sh(
      "cmake",
      "--build \(binPath)",
      "--config RelWithDebInfo",
      "--target install"
    )
    
    try? mkdir("\(binPath)/tmp")

    // 1. makeing dylib
    
    try? mkdir("\(binPath)/obj")
    try cd("\(binPath)/obj") {
      try sh("ar -x \(cwd)/\(libPath)/lib/libssh.a")
    }
    
    // dynamic framework
    try sh(
      "ld",
      "\(binPath)/obj/*.o",
      "-dylib",
      "-lSystem",
      "-lz",
      "-F\(opensslRoot)/Frameworks/\(p.opensslPlatform)",
      "-framework Foundation",
      "-framework OpenSSL",
      "-arch \(arch)",
      "-platform_version \(p.ldPlatformName) \(p.deploymentTarget) \(p.deploymentTarget)",
      "-syslibroot \(p.sdkPath())",
      "-compatibility_version 1.0.0",
      "-current_version 1.0.0",
      "-application_extension",
      "-o \(binPath)/\(Config.frameworkName)"
    )
    
    try sh(
      "install_name_tool",
      "-id",
      "@rpath/\(Config.frameworkName).framework/\(Config.frameworkName)",
      "\(binPath)/\(Config.frameworkName)"
    )
    
    try sh("rm -rf \(binPath)/obj")
    
    
    // 2. creating static lib
    try mkdir("\(binPath)/lib")
    try sh(
      "lipo -create \(libPath)/lib/libssh.a -output \(binPath)/tmp/libssh.a"
    )
  }
  
  let arch = buildArchs[0]
  
  let libPath = "lib/\(p.name)-\(arch).sdk"
  
  let plist = try p.plist(
    name: Config.frameworkName,
    version: Config.libsshVersion,
    id: "org.libssh",
    minSdkVersion: p.deploymentTarget
  )
  
  let moduleMap = p.module(name: Config.frameworkName, headers: .umbrellaDir("."))
  
  for path in [frameworkStaticPath, frameworkDynamicPath] {
    try? sh("rm -rf", path)
    try mkdir("\(path)/Headers")
    try sh("cp \(libPath)/include/libssh/*.h \(path)/Headers/")
    try write(content: plist, atPath: "\(path)/Info.plist")
    try mkdir("\(path)/Modules")
    try write(content: moduleMap, atPath: "\(path)/Modules/module.modulemap")
  }
  
  let aFiles = buildArchs.map { arch -> String in
    "bin/\(p.name)-\(arch).sdk/tmp/*.a"
  }

  try sh("libtool -static -o \(frameworkStaticPath)/\(Config.frameworkName) \(aFiles.joined(separator: " "))")

  let dylibFiles = buildArchs.map { arch -> String in
    "bin/\(p.name)-\(arch).sdk/\(Config.frameworkName)"
  }
  
  try sh("lipo -create \(dylibFiles.joined(separator: " ")) -output \(frameworkDynamicPath)/\(Config.frameworkName)")
  
  if p == .MacOSX {
    for path in [frameworkStaticPath, frameworkDynamicPath] {
      try repackFrameworkToMacOS(at: path, name: Config.frameworkName)
    }
  }
}


try? sh("rm -rf xcframeworks")
try mkdir("xcframeworks/dynamic")
try mkdir("xcframeworks/static")

let xcframeworkName = "\(Config.frameworkName).xcframework"
let xcframeworkdDynamicZipName = "\(Config.frameworkName)-dynamic.xcframework.zip"
let xcframeworkdStaticZipName = "\(Config.frameworkName)-static.xcframework.zip"
try? sh("rm \(xcframeworkdDynamicZipName)")
try? sh("rm \(xcframeworkdStaticZipName)")

try sh(
  "xcodebuild -create-xcframework \(dynamicFrameworkPaths.map {"-framework \($0)"}.joined(separator: " ")) -output xcframeworks/dynamic/\(xcframeworkName)"
)

try cd("xcframeworks/dynamic/") {
  try sh("zip --symlinks -r ../../\(xcframeworkdDynamicZipName) \(xcframeworkName)")
}

try sh(
  "xcodebuild -create-xcframework \(staticFrameworkPaths.map {"-framework \($0)"}.joined(separator: " ")) -output xcframeworks/static/\(xcframeworkName)"
)


try cd("xcframeworks/static/") {
  try sh("zip --symlinks -r ../../\(xcframeworkdStaticZipName) \(xcframeworkName)")
}


let releaseMD =
  """
    | File                          | SHA256                                       |
    | ----------------------------- |:--------------------------------------------:|
    | \(xcframeworkdDynamicZipName) | \(try sha(path: xcframeworkdDynamicZipName)) |
    | \(xcframeworkdStaticZipName)  | \(try sha(path: xcframeworkdStaticZipName))  |
  """

try write(content: releaseMD, atPath: "release.md")
