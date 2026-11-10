import Foundation
import SwiftUI

/// 极简版大字号样式（长辈友好）。
enum ElderUI {
    /// 页面标题。
    static let titleFont = Font.system(size: 28, weight: .bold)
    /// 大按钮文字。
    static let buttonFont = Font.system(size: 22, weight: .semibold)
    /// 列表主标题。
    static let rowTitleFont = Font.system(size: 20, weight: .medium)
    /// 次要信息。
    static let captionFont = Font.system(size: 15)

    /// 大号圆角按钮（最小点击区域 56pt）。
    static func bigButton(title: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 22, weight: .semibold))
            }
            Text(title).font(buttonFont)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 56)
        .padding(.horizontal, 16)
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    }
}
