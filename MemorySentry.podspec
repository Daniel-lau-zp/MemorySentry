Pod::Spec.new do |s|
  s.name             = 'MemorySentry'
  s.version          = '1.0.0'
  s.summary          = '零侵入的全局内存监视器 (App 整体字节阈值 / 内存压力分级告警 / 现场快照取证 / MetricKit 兜底)'
  s.description      = <<-DESC
    MemorySentry 是一个轻量、零侵入的全局内存监视器（iOS-only），纯 Swift 实现。
    挂上 observer、startMonitoring() 即可，无需业务侧任何登记 API。监控线：
    1) App 整体字节阈值告警 —— 轮询 phys_footprint（Jetsam 口径），跨越业务自定红线即上报，
       并自动采集全进程内存现场快照（按 VM tag 归类、单块大区域归因推测）。
    2) 内存压力分级告警 —— 按设备总内存自适应分档（设备越小阈值越低），warning / critical 双级
       边沿迟滞触发。
    3) MetricKit 兜底 —— 订阅系统次日交付的 OOM / 内存峰值诊断。
  DESC

  s.homepage         = 'https://github.com/liuzeping/MemorySentry'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'liuzeping' => 'liuzeping@example.com' }
  s.source           = { :git => 'https://github.com/liuzeping/MemorySentry.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'

  s.swift_versions = ['5.9']
  s.source_files = 'Sources/MemorySentry/**/*.swift'

  s.frameworks = 'Foundation', 'UIKit', 'MetricKit'
end
