//
//  Soundcore_UtilitiesApp.swift
//  Soundcore Utilities
//

import SwiftUI

@main
struct Soundcore_UtilitiesApp: App {
    private let bluetooth = BluetoothManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bluetooth)
        }
    }
}
