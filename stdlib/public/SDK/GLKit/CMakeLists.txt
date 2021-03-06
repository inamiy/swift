cmake_minimum_required(VERSION 3.4.3)
include("../../../../cmake/modules/StandaloneOverlay.cmake")

add_swift_library(swiftGLKit ${SWIFT_SDK_OVERLAY_LIBRARY_BUILD_TYPES} IS_SDK_OVERLAY
  GLKMath.swift.gyb

  SWIFT_COMPILE_FLAGS "${SWIFT_RUNTIME_SWIFT_COMPILE_FLAGS}"
  LINK_FLAGS "${SWIFT_RUNTIME_SWIFT_LINK_FLAGS}"
  TARGET_SDKS OSX IOS IOS_SIMULATOR TVOS TVOS_SIMULATOR
  SWIFT_MODULE_DEPENDS_OSX Darwin AppKit CoreData CoreGraphics CoreImage Dispatch Foundation IOKit ObjectiveC QuartzCore simd XPC # auto-updated
  SWIFT_MODULE_DEPENDS_IOS Darwin CoreGraphics CoreImage Dispatch Foundation ObjectiveC os QuartzCore simd UIKit # auto-updated
  SWIFT_MODULE_DEPENDS_TVOS Darwin CoreGraphics CoreImage Dispatch Foundation ObjectiveC QuartzCore simd UIKit # auto-updated
  FRAMEWORK_DEPENDS GLKit

  DEPLOYMENT_VERSION_OSX ${SWIFTLIB_DEPLOYMENT_VERSION_GLKIT_OSX}
  DEPLOYMENT_VERSION_IOS ${SWIFTLIB_DEPLOYMENT_VERSION_GLKIT_IOS}
  DEPLOYMENT_VERSION_TVOS ${SWIFTLIB_DEPLOYMENT_VERSION_GLKIT_TVOS}
)
