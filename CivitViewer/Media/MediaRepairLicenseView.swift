import SwiftUI

struct MediaRepairLicenseView: View {
    private let website = URL(string: "https://ffmpeg.org/")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                PageContentCard {
                    VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                        Text("FFmpeg").font(AppTypography.rowTitle)
                        Text("本机视频修复使用 FFmpeg 读取、转封装和解码。")
                            .font(AppTypography.supportingText)
                    }
                    .padding(.vertical, FloatingPageChrome.cardInset)
                }

                NavigationLink {
                    MediaRepairLicenseDetailView()
                } label: {
                    PageContentCard {
                        HStack(spacing: FloatingPageChrome.spacing) {
                            VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                                Text("查看许可证").font(AppTypography.rowTitle)
                                Text("FFmpeg · LGPL")
                                    .font(AppTypography.supportingText)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            FloatingPageIcon(symbol: "chevron.right")
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, FloatingPageChrome.cardInset)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("opensource.ffmpeg-license")
            }
            .pageScrollContentInsets()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .floatingTitleBar("开源组件") {
            Link(destination: website) {
                FloatingPageIcon(symbol: "safari")
            }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .accessibilityLabel("打开 FFmpeg 官方网站")
            .accessibilityIdentifier("opensource.ffmpeg-website")
        }
        .ordinaryAppearance()
    }
}

private struct MediaRepairLicenseDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                PageContentCard {
                    VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                        Text("This software uses libraries from the FFmpeg project under the LGPLv2.1 or later.")
                            .font(AppTypography.supportingText)
                        Text("本机视频修复使用 FFmpeg 读取、转封装和解码，使用 Apple VideoToolbox 编码兼容视频。本构建未启用 GPL、nonfree 或 libx264。")
                            .font(AppTypography.supportingText)
                    }
                    .padding(.vertical, FloatingPageChrome.cardInset)
                }

                if let url = Bundle.main.url(forResource: "FFmpeg-LGPL", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) {
                    PageContentCard {
                        Text(text)
                            .accessibilityIdentifier("opensource.ffmpeg-license-text")
                            .font(AppTypography.supportingText)
                            .lineSpacing(FloatingPageChrome.spacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, FloatingPageChrome.cardInset)
                    }
                }
            }
            .pageScrollContentInsets()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .floatingTitleBar("FFmpeg 许可证")
        .ordinaryAppearance()
    }
}
