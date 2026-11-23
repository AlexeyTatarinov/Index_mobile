// SPDX-License-Identifier: GPL-3.0-or-later
//
// Search field with a big voice button. Sits at the bottom of the screen,
// where the thumb reaches it on a large phone.

import SwiftUI

struct SearchBar: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let isRecording: Bool
    let onSubmit: () -> Void
    let onMic: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Что найти?", text: $text)
                    .focused(focus)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .onSubmit(onSubmit)
                    .accessibilityIdentifier("searchField")
                if !text.isEmpty {
                    Button {
                        text = ""
                        focus.wrappedValue = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))

            Button(action: onMic) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(isRecording ? Color.red : Color.accentColor, in: Circle())
                    .symbolEffect(.pulse, isActive: isRecording)
                    .shadow(color: (isRecording ? Color.red : Color.accentColor).opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Остановить запись" : "Голосовой поиск")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

/// Shown above the search bar while the microphone is on.
struct ListeningBanner: View {
    let transcript: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(transcript.isEmpty ? "Слушаю… Говори запрос, потом нажми ■" : transcript)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
