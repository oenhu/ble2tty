//
//  InsertableTextField.swift
//  支持从外部在光标处插入文本的输入框(NSTextField 封装)
//

import SwiftUI
import AppKit

/// 插入控制器: 变量按钮通过它向输入框光标处插入文本
final class TextFieldInsertion: ObservableObject {
    fileprivate weak var field: NSTextField?

    /// 在光标处插入(有选中则替换选中); 输入框未聚焦时追加到末尾
    func insert(_ text: String) {
        guard let tf = field else { return }
        if let editor = tf.currentEditor() as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange)
        } else {
            tf.stringValue += text
        }
        // 同步回 SwiftUI binding
        tf.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: tf))
        tf.window?.makeFirstResponder(tf)   // 插入后聚焦, 便于连续点击变量按钮
    }
}

struct InsertableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = true
    let insertion: TextFieldInsertion

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: InsertableTextField
        init(_ parent: InsertableTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let tf = notification.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.placeholderString = placeholder
        tf.delegate = context.coordinator
        tf.bezelStyle = .roundedBezel
        tf.isBezeled = true
        if monospaced {
            tf.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        tf.lineBreakMode = .byTruncatingTail
        insertion.field = tf
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        // 非编辑状态下同步外部变更(如点了"默认"按钮); 编辑中不打断
        if tf.currentEditor() == nil, tf.stringValue != text {
            tf.stringValue = text
        }
    }
}
