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

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
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

            // Mic only dictates into the field, so the text can be checked or edited.
            Button(action: onMic) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isRecording ? Color.white : Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(isRecording ? Color.red : Color.accentColor.opacity(0.14), in: Circle())
                    .symbolEffect(.pulse, isActive: isRecording)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Остановить диктовку" : "Диктовать запрос")

            // Send runs the search, also stopping dictation if it is still on.
            Button(action: onSubmit) {
                Image(systemName: "arrow.up")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(canSend ? Color.accentColor : Color.gray.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Искать")
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
            Text(transcript.isEmpty ? "Слушаю… Скажи запрос. ■ остановит, ↑ сразу найдёт" : transcript)
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
