import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  @ObservedObject var viewModel: WearablesViewModel
  let onRegistered: () -> Void
  @State private var showSettings = false
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.glasses.rawValue

  var body: some View {
    NavigationStack {
      ZStack {
        GlassifAIBackdrop()
        ScrollView {
          VStack(spacing: 32) {
            Spacer(minLength: 36)
            GlassifAIMark(size: 104)
            VStack(spacing: 10) {
              Text("Connect Meta glasses")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
              Text("Give GlassifAI your first-person camera view.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 18) {
              capability("Ask hands-free visual questions", icon: "viewfinder")
              capability("Hear live, interruptible answers", icon: "waveform")
              capability("Keep credentials on your iPhone", icon: "lock.fill")
            }
            .padding(.vertical, 8)

            VStack(spacing: 12) {
              Button {
                viewModel.connectGlasses()
              } label: {
                HStack {
                  Image(systemName: "eyeglasses")
                  Text(viewModel.registrationState == .registering ? "Connecting…" : "Connect glasses")
                  if viewModel.registrationState == .registering {
                    Spacer()
                    ProgressView()
                  }
                }
                .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .buttonBorderShape(.roundedRectangle(radius: 14))
              .controlSize(.large)
              .disabled(viewModel.registrationState == .registering)

              Button {
                captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
              } label: {
                Label("Use iPhone camera", systemImage: "iphone")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
              .buttonBorderShape(.roundedRectangle(radius: 14))
              .controlSize(.large)
            }

            Text("Meta AI opens briefly to approve the connection.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: 420)
          .padding(.horizontal, 28)
          .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { showSettings = true } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Open GlassifAI settings")
        }
      }
    }
    .sheet(isPresented: $showSettings) { SettingsView() }
    .onChange(of: viewModel.registrationState) { _, state in
      if state == .registered { onRegistered() }
    }
    .onAppear {
      if viewModel.registrationState == .registered { onRegistered() }
    }
  }

  private func capability(_ title: String, icon: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .foregroundStyle(.tint)
        .frame(width: 24)
      Text(title)
        .font(.body)
      Spacer(minLength: 0)
    }
  }
}
