//
//  GlassZoomSlider.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/10/26.
//

import SwiftUI

struct GlassZoomSlider: View {
    @Binding var value: Double // 0.0 (Bottom/Zoom Out) to 1.0 (Top/Zoom In)
    @State private var isTouching = false
    
    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let thumbSize = 36.0
            
            // Calculate thumb position based on value
            // Value 1.0 (Top) -> y = 0
            // Value 0.0 (Bottom) -> y = height - thumbSize
            let trackLength = height - thumbSize
            let thumbOffset = (1.0 - value) * trackLength
            
            ZStack(alignment: .top) {
                
                // 1. The Touch Area (Invisible Sensor)
                // We put this first so it defines the frame, but we add the gesture to the whole ZStack
                Color.white.opacity(0.001) // Invisible but touchable
                    .frame(width: 60) // Wide touch area for easy grabbing
                
                // 2. The Glass Track
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(width: 6, height: height)
                    .shadow(color: .white.opacity(0.2), radius: 0, x: 1, y: 0)
                
                // 3. The Glass Ball Thumb
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 3)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(y: thumbOffset)
                    // Visual pop when touching
                    .scaleEffect(isTouching ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3), value: isTouching)
            }
            // 4. THE FIX: The Gesture is on the container, not the ball
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isTouching = true
                        
                        // Map Y position to 0.0-1.0 range
                        // Y=0 (Top) -> 1.0
                        // Y=Height (Bottom) -> 0.0
                        let y = drag.location.y - (thumbSize / 2)
                        let percent = 1.0 - (y / trackLength)
                        
                        // Clamp and update
                        self.value = min(max(percent, 0), 1)
                    }
                    .onEnded { _ in
                        isTouching = false
                    }
            )
        }
        .frame(width: 60) // Fixed width container
    }
}
