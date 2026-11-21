import SwiftUI
import Observation

struct AvatarView: View {
    let name: String
    var size: CGFloat = 43
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.18, green: 0.36, blue: 0.43), in: Circle())
    }
}

/// Shared list numbering reserves the width of four digits without zero padding.
struct OrdinalLabel: View {
    let position: Int
    var body: some View {
        ZStack {
            Text("0000").hidden().accessibilityHidden(true)
            Text(String(position))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct AuthorRowIdentity: View {
    let name: String
    var showsHandle = false
    var detail: String? = nil
    var position: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let position {
                OrdinalLabel(position: position)
            }
            HStack(spacing: FloatingPageChrome.spacing) {
                AvatarView(name: name, size: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(showsHandle ? "@" + name : name)
                        .font(FloatingPageChrome.controlFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension View {
    func authorCardRow(horizontalInset: Bool = true) -> some View {
        padding(.horizontal, horizontalInset ? FloatingPageChrome.cardInset : 0)
            .padding(.vertical, FloatingPageChrome.groupInset)
            .frame(minHeight: FloatingPageChrome.controlHeight)
    }
}

struct CreatorIdentityCard: View {
    let creator: Creator

    var body: some View {
        HStack(spacing: FloatingPageChrome.spacing) {
            AuthorRowIdentity(name: creator.username, showsHandle: true)
            Spacer(minLength: FloatingPageChrome.groupInset)
            FollowButton(creator: creator)
        }
        .padding(.horizontal, FloatingPageChrome.cardInset)
        .padding(.vertical, FloatingPageChrome.groupInset)
        .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
    }
}
