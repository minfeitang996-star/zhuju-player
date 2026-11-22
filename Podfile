platform :ios, '16.4'
source 'https://cdn.cocoapods.org'

target 'ZhuJu' do
  use_frameworks!
  pod 'MobileVLCKit', '~> 3.7.5'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      c.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
      c.build_settings['CODE_SIGN_IDENTITY'] = ''
      c.build_settings['EXPANDED_CODE_SIGN_IDENTITY'] = ''
      c.build_settings['ENABLE_BITCODE'] = 'NO'
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.4'
    end
  end
end
