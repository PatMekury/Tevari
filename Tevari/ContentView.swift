//
//  ContentView.swift
//  Tevari
//

import SwiftUI

/// The app's initial visual state. This stays independent from routing so the
/// eventual session coordinator can decide where to continue after launch.
struct ContentView: View {
    @State private var hasFinishedLaunching = false

    var body: some View {
        ZStack {
            Color.tevariMidnight
                .ignoresSafeArea()

            AuthenticationView()
                .opacity(hasFinishedLaunching ? 1 : 0)

            if !hasFinishedLaunching {
                LaunchScreenView()
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.easeInOut(duration: 0.55)) {
                hasFinishedLaunching = true
            }
        }
    }
}

struct LaunchScreenView: View {
    @State private var hasAppeared = false
    @State private var breathes = false
    @State private var rotates = false

    var body: some View {
        ZStack {
            Color.tevariMidnight
                .ignoresSafeArea()

            ambientLight

            VStack(spacing: 0) {
                Spacer()

                brandMark

                Spacer()
                    .frame(height: 34)

                titleBlock

                Spacer()

                loadingIndicator
                    .padding(.bottom, 52)
            }
            .padding(.horizontal, 28)
        }
        .preferredColorScheme(.dark)
        .task {
            guard !hasAppeared else { return }

            withAnimation(.spring(response: 0.9, dampingFraction: 0.76)) {
                hasAppeared = true
            }

            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                breathes = true
            }

            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                rotates = true
            }
        }
    }

    private var ambientLight: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(Color.tevariGold.opacity(0.23))
                    .frame(width: proxy.size.width * 0.92)
                    .blur(radius: 70)
                    .offset(x: breathes ? -72 : -42, y: breathes ? -240 : -210)

                Circle()
                    .fill(Color.tevariSage.opacity(0.20))
                    .frame(width: proxy.size.width * 0.85)
                    .blur(radius: 82)
                    .offset(x: breathes ? 94 : 60, y: breathes ? 252 : 220)

                Circle()
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
                    .frame(width: proxy.size.width * 1.35)
                    .rotationEffect(.degrees(rotates ? 360 : 0))
                    .offset(y: -75)
            }
        }
        .ignoresSafeArea()
    }

    private var brandMark: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 154, height: 154)
                .tevariGlass(in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.7), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: Color.tevariGold.opacity(0.22), radius: 32, y: 13)

            Image(systemName: "sparkles")
                .font(.system(size: 49, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color.tevariGold],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .tevariPulseSymbol(isActive: hasAppeared)
        }
        .scaleEffect(hasAppeared ? 1 : 0.74)
        .opacity(hasAppeared ? 1 : 0)
    }

    private var titleBlock: some View {
        VStack(spacing: 10) {
            Text("TEVARI")
                .font(.system(size: 29, weight: .medium, design: .default))
                .tracking(8)
                .foregroundStyle(.white)

            Text("Scripture for the moment you are in")
                .font(.system(size: 15, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.66))
        }
        .offset(y: hasAppeared ? 0 : 14)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.7).delay(0.2), value: hasAppeared)
    }

    private var loadingIndicator: some View {
        HStack(spacing: 9) {
            ProgressView()
                .tint(Color.tevariGold)

            Text("Preparing your space")
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .tevariGlass(in: Capsule())
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.65).delay(0.42), value: hasAppeared)
    }
}

extension Color {
    static let tevariMidnight = Color(red: 0.035, green: 0.071, blue: 0.106)
    static let tevariGold = Color(red: 0.94, green: 0.76, blue: 0.42)
    static let tevariSage = Color(red: 0.34, green: 0.67, blue: 0.60)
}

extension View {
    /// Keeps the Liquid Glass treatment on current systems while giving iOS 16
    /// users an equivalent translucent card instead of raising availability errors.
    @ViewBuilder
    func tevariGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.white.opacity(0.10), in: shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 1))
        }
    }

    @ViewBuilder
    func tevariScrollBounceBehavior() -> some View {
        if #available(iOS 16.4, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }

    @ViewBuilder
    func tevariPulseSymbol(isActive: Bool) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.pulse.byLayer, options: .repeating, isActive: isActive)
        } else {
            self
        }
    }
}

#Preview {
    LaunchScreenView()
}
