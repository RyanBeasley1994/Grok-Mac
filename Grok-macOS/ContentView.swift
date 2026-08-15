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
            .frame(minWidth: 800, minHeight: 600)
            .ignoresSafeArea()
            .background(WindowGrabber())
            // Thin strip under the traffic lights so the window can still be dragged.
            .overlay(alignment: .top) {
                TitlebarDragRegion()
                    .frame(height: 28)
                    .padding(.leading, 78)
            }
    }
}
