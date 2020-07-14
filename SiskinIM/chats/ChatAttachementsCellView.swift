//
//  ChatAttachementsCellView.swift
//  Siskin IM
//
//  Created by Andrzej Wójcik on 03/01/2020.
//  Copyright © 2020 Tigase, Inc. All rights reserved.
//

import UIKit
import MobileCoreServices
import TigaseSwift

class ChatAttachmentsCellView: UICollectionViewCell, UIDocumentInteractionControllerDelegate, UIContextMenuInteractionDelegate {

    @IBOutlet var imageField: UIImageView!

    private var id: Int {
        return item?.id ?? NSNotFound;
    };
    private var item: ChatAttachment?;
    
    func set(item: ChatAttachment) {
        self.item = item;
        
        if #available(iOS 13.0, *), self.interactions.isEmpty {
            self.addInteraction(UIContextMenuInteraction(delegate: self));
        }
        
        if let fileUrl = DownloadStore.instance.url(for: "\(item.id)") {
            if #available(iOS 13.0, *), let imageProvider = MetadataCache.instance.metadata(for: "\(item.id)")?.imageProvider {
                imageField.image = UIImage.icon(forFile: fileUrl, mimeType: nil);
                imageProvider.loadItem(forTypeIdentifier: kUTTypeImage as String, options: nil, completionHandler: { (data, error) in
                    guard let data = data, error == nil else {
                        return;
                    }
                    DispatchQueue.main.async {
                        guard self.id == item.id else {
                            return;
                        }
                        switch data {
                        case let image as UIImage:
                            self.imageField.image = image;
                        case let data as Data:
                            self.imageField.image = UIImage(data: data);
                        default:
                            break;
                        }
                    }
                });
            } else if let image = UIImage(contentsOfFile: fileUrl.path) {
                self.imageField.image = image;
            } else {
                self.imageField.image = UIImage.icon(forFile: fileUrl, mimeType: nil);
            }
        } else {
            if let mimetype = item.appendix.mimetype, let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mimetype as CFString, nil)?.takeRetainedValue() as String? {
                imageField.image = UIImage.icon(forUTI: uti);
            } else {
                imageField.image = UIImage.icon(forUTI: "public.content")
            }
        }
    }
    
    @available(iOS 13.0, *)
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { suggestedActions in
            return self.prepareContextMenu();
        })
    }
    
    @available(iOS 13.0, *)
    func prepareContextMenu() -> UIMenu {
        guard let item = self.item else {
            return UIMenu(title: "");
        }
        
        if let localUrl = DownloadStore.instance.url(for: "\(item.id)") {
            let items = [
                UIAction(title: "Preview", image: UIImage(systemName: "eye.fill"), handler: { action in
                    print("preview called");
                    self.open(url: localUrl, preview: true);
                }),
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc"), handler: { action in
                    guard let text = self.item?.copyText(withTimestamp: Settings.CopyMessagesWithTimestamps.getBool(), withSender: false) else {
                        return;
                    }
                    UIPasteboard.general.strings = [text];
                    UIPasteboard.general.string = text;
                }),
                UIAction(title: "Share..", image: UIImage(systemName: "square.and.arrow.up"), handler: { action in
                    print("share called");
                    self.open(url: localUrl, preview: false);
                }),
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: [.destructive], handler: { action in
                    print("delete called");
                    DownloadStore.instance.deleteFile(for: "\(item.id)");
                    DBChatHistoryStore.instance.updateItem(for: item.account, with: item.jid, id: item.id, updateAppendix: { appendix in
                        appendix.state = .removed;
                    })
                })
            ];
            return UIMenu(title: localUrl.lastPathComponent, image: nil, identifier: nil, options: [], children: items);
        } else {
            return UIMenu(title: "");
        }
    }
    
    var documentController: UIDocumentInteractionController?;
    
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        let viewController = ((UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController?.presentedViewController)!;
        return viewController;
    }
    
    func open(url: URL, preview: Bool) {
        print("opening a file:", url, "exists:", FileManager.default.fileExists(atPath: url.path));// "tmp:", tmpUrl);
        let documentController = UIDocumentInteractionController(url: url);
        documentController.delegate = self;
        documentController.name = url.lastPathComponent;
        print("detected uti:", documentController.uti, "for:", documentController.url);
        if preview && documentController.presentPreview(animated: true) {
            self.documentController = documentController;
        } else if documentController.presentOptionsMenu(from: self.superview?.convert(self.frame, to: self.superview?.superview) ?? CGRect.zero, in: self, animated: true) {
            self.documentController = documentController;
        }
    }

}
