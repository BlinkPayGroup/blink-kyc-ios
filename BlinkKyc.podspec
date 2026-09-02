Pod::Spec.new do |s|
  s.name             = 'BlinkKyc'
  s.version          = '1.2.0'
  s.summary          = 'Blink KYC — drop-in identity verification for iOS.'
  s.description      = <<-DESC
    Drop-in identity verification for iOS. Your backend mints a session; the SDK runs the capture
    (document + liveness) and returns a verdict. A black box: you get VERIFIED / REJECTED / REVIEW
    and a neutral reason, never a score or any detail of how it was reached.
  DESC
  s.homepage         = 'https://blink-pay.net/kyc/'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'Blink' => 'sdk@blink-pay.net' }
  s.source           = { :git => 'https://github.com/BlinkPayGroup/blink-kyc-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.swift_versions        = ['5.9']

  s.source_files = 'Sources/BlinkKyc/**/*.swift'
  s.frameworks   = 'Foundation', 'UIKit', 'SwiftUI', 'AVFoundation', 'CoreImage', 'CoreMedia'

  # The host app must declare a camera usage description for the drop-in capture UI.
  # Add NSCameraUsageDescription to your Info.plist.
end
