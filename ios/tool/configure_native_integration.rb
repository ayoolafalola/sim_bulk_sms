#!/usr/bin/env ruby
# Adds Messages++'s native integration to the Xcode project. Safe to run again.
#   - Runner: NativeIntegrationBridge.swift, AppIntents.swift, Runner.entitlements
#   - ShareExtension target (com.comeriver.messages.ShareExtension), embedded in Runner
# Usage: ruby ios/tool/configure_native_integration.rb   (from the repo root)
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'No Runner target.'
runner_group = project.main_group['Runner'] or abort 'No Runner group.'

def add_source(group, target, name)
  ref = group.files.find { |f| f.path == name } || group.new_reference(name)
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
  ref
end

%w[NativeIntegrationBridge.swift AppIntents.swift].each { |f| add_source(runner_group, runner, f) }
runner_group.files.find { |f| f.path == 'Runner.entitlements' } || runner_group.new_reference('Runner.entitlements')
runner.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

ext_name = 'ShareExtension'
ext = project.targets.find { |t| t.name == ext_name }
unless ext
  ext = project.new_target(:app_extension, ext_name, :ios, '15.0', nil, :swift)
  ext.build_configurations.each do |config|
    s = config.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.comeriver.messages.ShareExtension'
    s['INFOPLIST_FILE'] = 'ShareExtension/Info.plist'
    s['CODE_SIGN_ENTITLEMENTS'] = 'ShareExtension/ShareExtension.entitlements'
    s['SWIFT_VERSION'] = '5.0'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    s['SKIP_INSTALL'] = 'YES'
    s['CODE_SIGN_STYLE'] = 'Automatic'
    s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
    s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
    # Same team as the app (set once in Xcode › Signing & Capabilities).
    team = runner.build_configurations.find { |c| c.name == config.name }&.build_settings&.dig('DEVELOPMENT_TEAM')
    s['DEVELOPMENT_TEAM'] = team if team
  end
  group = project.main_group[ext_name] || project.main_group.new_group(ext_name, ext_name)
  add_source(group, ext, 'ShareViewController.swift')
  %w[Info.plist ShareExtension.entitlements].each { |f| group.files.find { |r| r.path == f } || group.new_reference(f) }
  storyboard = group.children.find { |c| c.display_name == 'MainInterface.storyboard' } ||
               group.new_variant_group('MainInterface.storyboard').tap { |v| v.new_reference('Base.lproj/MainInterface.storyboard').name = 'Base' }
  ext.resources_build_phase.add_file_reference(storyboard)
  %w[Social Intents UniformTypeIdentifiers].each do |fw|
    ext.frameworks_build_phase.add_file_reference(project.frameworks_group.new_file("System/Library/Frameworks/#{fw}.framework", :sdk_root))
  end

  runner.add_dependency(ext)
  embed = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' } ||
          runner.new_copy_files_build_phase('Embed Foundation Extensions').tap { |p| p.symbol_dst_subfolder_spec = :plug_ins }
  build_file = embed.add_file_reference(ext.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  # Embed before Flutter's "Thin Binary" script so the extension is signed in the archive.
  phases = runner.build_phases
  thin = phases.find { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
  if thin && phases.index(embed) > phases.index(thin)
    phases.delete(embed)
    phases.insert(phases.index(thin), embed)
  end
end

# Every run: the extension's own settings (Flutter's version numbers, not the
# app's CocoaPods settings) and an explicit product name.
ext_group = project.main_group[ext_name]
xcconfig = ext_group.files.find { |f| f.path == 'ShareExtension.xcconfig' } || ext_group.new_reference('ShareExtension.xcconfig')
ext.build_configurations.each do |config|
  config.base_configuration_reference = xcconfig
  config.build_settings['PRODUCT_NAME'] = 'ShareExtension'
  config.build_settings.delete('CODE_SIGN_ENTITLEMENTS') if config.build_settings['CODE_SIGN_ENTITLEMENTS'].to_s.empty?
end

project.save
puts 'Messages++ native integration is in the Xcode project.'
puts 'In Xcode › Signing & Capabilities: pick the team for Runner and ShareExtension, and enable'
puts 'Push Notifications, Associated Domains and In-App Purchase.'
