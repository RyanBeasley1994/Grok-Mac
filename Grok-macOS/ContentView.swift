//
//  ContentView.swift
//  Grok-macOS
//
//  Created by Nicholas Hershy on 7/8/26.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var state: BrowserState

    var body: some View {
        WebView(model: state.activeTab)
            .frame(minWidth: 320, minHeight: 400)
            .ignoresSafeArea()
            .background(WindowGrabber())
    }
}
