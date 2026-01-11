//
//  TutorialOverlay.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/11/26.
//

import SwiftUI

struct TutorialOverlay: View {
    @Binding var step: Int
    var onFinish: () -> Void
    var onOpenLayers: () -> Void
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 1. Dark Background with Spotlights
                Color.black.opacity(0.85)
                    .mask(
                        ZStack {
                            Rectangle().fill(Color.white)
                            
                            // Step 1: Opacity Spotlight
                            if step == 1 {
                                let spotlightSize = geo.size.height * 0.92
                                Circle()
                                    .frame(width: spotlightSize, height: spotlightSize)
                                    .position(x: 0, y: geo.size.height)
                                    .blendMode(.destinationOut)
                            }
                            
                            // Step 2: Settings Spotlight
                            if step == 2 {
                                Circle()
                                    .frame(width: 75, height: 75)
                                    .position(x: geo.size.width - 51, y: geo.size.height - 23)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    )
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { nextStep() }
                
                // 2. Tutorial Content
                VStack {
                    Spacer()
                    
                    // STEP 0: WELCOME
                    if step == 0 {
                        VStack(spacing: 20) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.white)
                            Text("Welcome to LidarExplorer")
                                .font(.title).bold().foregroundColor(.white)
                            Text("Visualize the earth beneath the trees.")
                                .foregroundColor(.white.opacity(0.9))
                            Button("Start Tour") { nextStep() }
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .padding(.bottom, 250)
                    }
                    
                    // STEP 1: OPACITY
                    if step == 1 {
                        ZStack {
                            VStack(alignment: .leading) {
                                Text("Lidar & Opacity")
                                    .font(.title2).bold().foregroundColor(.white)
                                Text("Fade the Lidar layer to see the map underneath.")
                                    .foregroundColor(.white)
                                    .frame(width: 250, alignment: .leading)
                            }
                            .offset(x: 250, y: -560)
                            
                            Image(systemName: "arrow.down.left")
                                .font(.system(size: 60, weight: .bold))
                                .foregroundColor(.white)
                                .offset(x: 185, y: -490)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    
                    // STEP 2: SETTINGS
                    if step == 2 {
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("Settings & Cache")
                                    .font(.title2).bold().foregroundColor(.white)
                                Text("Manage storage to save space.")
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.trailing)
                                
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 50))
                                    .foregroundColor(.white)
                                    .rotationEffect(.degrees(-25))
                                    .padding(.trailing, 30)
                                    .padding(.bottom, 10)
                            }
                            .padding(.bottom, 85)
                            .padding(.trailing, 20)
                        }
                    }
                }
            }
        }
    }
    
    func nextStep() {
        withAnimation {
            step += 1
            if step == 1 { onOpenLayers() }
            if step > 2 { onFinish() }
        }
    }
}
