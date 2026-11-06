//
//  DeviceCheck.swift
//  Sentry
//
//  Created by 秋星桥 on 5/24/25.
//

import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import SystemConfiguration

enum DeviceCheck {
    // 以类型安全的会话快照补充锁屏通知，缺少会话信息时保留未知状态，喵~
    static func isMacLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        return (session[kCGSessionLoginDoneKey as String] as? Bool).map { !$0 }
    }

    static func isMacLidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }

        defer { IOObjectRelease(service) }

        let clamshellStateKey = "AppleClamshellState" as CFString
        let clamshellState = IORegistryEntryCreateCFProperty(service, clamshellStateKey, kCFAllocatorDefault, 0)

        if let state = clamshellState?.takeRetainedValue() as? Bool {
            return state
        }

        return nil
    }

    static func isConnectedToWirelessNetwork() -> Bool {
        var zeroAddress = sockaddr_in(sin_len: 0, sin_family: 0, sin_port: 0, sin_addr: in_addr(s_addr: 0), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
        zeroAddress.sin_family = sa_family_t(AF_INET)

        let defaultRouteReachability = withUnsafePointer(to: &zeroAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { zeroSockAddress in
                SCNetworkReachabilityCreateWithAddress(nil, zeroSockAddress)
            }
        }

        var flags = SCNetworkReachabilityFlags(rawValue: 0)
        if SCNetworkReachabilityGetFlags(defaultRouteReachability!, &flags) == false {
            return false
        }

        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    static func isConnectedToPower() -> Bool {
        if IOPSCopyExternalPowerAdapterDetails() != nil {
            return true
        }

        guard let powerInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSources = IOPSCopyPowerSourcesList(powerInfo)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return false
        }

        for powerSource in powerSources {
            if let description = IOPSGetPowerSourceDescription(powerInfo, powerSource)?.takeUnretainedValue() as? [String: Any] {
                if let powerState = description[kIOPSPowerSourceStateKey] as? String {
                    if powerState == kIOPSACPowerValue {
                        return true
                    }
                }
            }
        }

        return false
    }

    static func getBatteryLevel() -> Int? {
        guard let powerInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSources = IOPSCopyPowerSourcesList(powerInfo)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }

        for powerSource in powerSources {
            if let description = IOPSGetPowerSourceDescription(powerInfo, powerSource)?.takeUnretainedValue() as? [String: Any] {
                if let type = description[kIOPSTypeKey] as? String,
                   type == kIOPSInternalBatteryType
                {
                    if let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                       let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                       maxCapacity > 0
                    {
                        return (currentCapacity * 100) / maxCapacity
                    }
                }
            }
        }

        return nil
    }
}
