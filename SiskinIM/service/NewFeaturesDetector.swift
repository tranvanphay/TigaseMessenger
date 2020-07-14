//
// NewFeaturesDetector.swift
//
// Siskin IM
// Copyright (C) 2018 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//
import UIKit
import TigaseSwift

class NewFeaturesDetector: XmppServiceEventHandler {
    
    let events: [Event] = [DiscoveryModule.AccountFeaturesReceivedEvent.TYPE];
    
    let suggestions: [NewFeaturesDetectorSuggestion] = [MAMSuggestion(), PushSuggestion()];
    weak var xmppService: XmppService?;
    
    fileprivate var allControllers: [NewFeatureSuggestionView] = [];
    fileprivate var inProgress: Bool = false;
    
    func showNext() {
        DispatchQueue.main.async {
            guard !self.allControllers.isEmpty else {
                self.inProgress = false;
                return;
            }
            let controller = self.allControllers.remove(at: 0)
            UIApplication.shared.keyWindow?.rootViewController?.present(controller, animated: true, completion: nil);
        }
    }
    
    func completionHandler(controllers: [NewFeatureSuggestionView]) {
        DispatchQueue.main.async {
            self.allControllers.append(contentsOf: controllers);
            guard !self.inProgress else {
                return;
            }
            self.inProgress = true;
            self.showNext();
        }
    }
    
    func handle(event: Event) {
        switch event {
        case let e as DiscoveryModule.AccountFeaturesReceivedEvent:
            guard let account = e.sessionObject.userBareJid, let xmppService = self.xmppService else {
                return;
            }
            guard DispatchQueue.main.sync(execute: { return UIApplication.shared.applicationState == .active }) else {
                return;
            }

            let knownFeatures: [String] = AccountSettings.KnownServerFeatures(account).getStrings() ?? [];
            let newFeatures = e.features.filter { (feature) -> Bool in
                return !knownFeatures.contains(feature);
            };
            
            suggestions.forEach { suggestion in
                suggestion.handle(xmppService: xmppService, account: account, newServerFeatures: newFeatures, onNext: self.showNext, completionHandler: self.completionHandler);
            }
            
            let newKnownFeatures = e.features.filter { feature -> Bool in
                return suggestions.contains(where: { (suggestion) -> Bool in
                    return suggestion.isCapable(feature);
                })
            }
            
            AccountSettings.KnownServerFeatures(account).set(strings: newKnownFeatures);
            
            break;
        default:
            break;
        }
    }
    
    class MAMSuggestion: NewFeaturesDetectorSuggestion {
        
        let feature = MessageArchiveManagementModule.MAM_XMLNS;
        
        func isCapable(_ feature: String) -> Bool {
            return self.feature == feature;
        }

        func handle(xmppService: XmppService, account: BareJID, newServerFeatures features: [String], onNext: @escaping ()->Void, completionHandler: @escaping ([NewFeatureSuggestionView])->Void) {
            guard features.contains(feature) else {
                completionHandler([]);
                return;
            }
            
            askToEnableMAM(xmppService: xmppService, account: account, onNext: onNext, completionHandler: completionHandler);
        }
     
        fileprivate func askToEnableMAM(xmppService: XmppService, account: BareJID, onNext: @escaping ()->Void, completionHandler: @escaping ([NewFeatureSuggestionView])->Void) {
            guard let mamModule: MessageArchiveManagementModule = xmppService.getClient(forJid: account)?.modulesManager.getModule(MessageArchiveManagementModule.ID) else {
                completionHandler([]);
                return;
            }
            
            mamModule.retrieveSettings(completionHandler: { result in
                switch result {
                case .success(let defValue, let always, let never):
                    if defValue == .never {
                        DispatchQueue.main.async {
                            let controller = UIStoryboard(name: "Main", bundle: Bundle.main).instantiateViewController(withIdentifier: "NewFeatureSuggestionView") as! NewFeatureSuggestionView;
                            
                            _ = controller.view;
                            
                            controller.titleField.text = "Message Archiving";
                            controller.iconField.image = UIImage(named: "messageArchiving")
                            controller.descriptionField.text = """
                            Your server for account \(account) supports message archiving.
                            
                            When it is enabled your XMPP server will archive all messages which you exchange. This will allow any XMPP client which you use and which supports message archiving to query this archive and show you message history even if messages were sent using different XMPP client.
                            """;
                            controller.onSkip = {
                                controller.dismiss(animated: true, completion: onNext);
                            }
                            controller.onEnable = { (handler) in
                                mamModule.updateSettings(defaultValue: .always, always: always, never: never, completionHandler: { result in
                                    switch result {
                                    case .success(_, _, _):
                                        DispatchQueue.main.async {
                                            handler();
                                            self.askToEnableMessageSync(xmppService: xmppService, account: account, onNext: onNext, completionHandler: { subcontrollers in
                                                guard let toShow = subcontrollers.first else {
                                                    controller.dismiss(animated: true, completion: onNext);
                                                    return;
                                                }
                                                controller.dismiss(animated: true, completion: {
                                                    UIApplication.shared.keyWindow?.rootViewController?.present(toShow, animated: true, completion: nil);
                                                })
                                            });
                                        }
                                    case .failure(_, _):
                                        DispatchQueue.main.async {
                                            handler();
                                            self.showError(title: "Message Archiving Error", message: "Server \(account.domain) returned an error on the request to enable archiving. You can try to enable this feature later on from the account settings.");
                                        }
                                    }
                                });
                            };
                            
                            completionHandler([controller]);
                        }
                    } else {
                        self.askToEnableMessageSync(xmppService: xmppService, account: account, onNext: onNext, completionHandler: completionHandler);
                    }
                case .failure(_, _):
                    completionHandler([]);
                }
            });

        }
        
        fileprivate func askToEnableMessageSync(xmppService: XmppService, account: BareJID, onNext: @escaping ()->Void, completionHandler: @escaping ([NewFeatureSuggestionView])->Void) {
            guard !AccountSettings.messageSyncAuto(account).getBool() else {
                completionHandler([]);
                return;
            }
            
            DispatchQueue.main.async {
                let controller = UIStoryboard(name: "Main", bundle: Bundle.main).instantiateViewController(withIdentifier: "NewFeatureSuggestionView") as! NewFeatureSuggestionView;
                
                _ = controller.view;

                controller.titleField.text = "Message Synchronization";
                controller.iconField.image = UIImage(named: "messageArchiving")
                controller.descriptionField.text = """
Would you like to enable automatic message synchronization?
                
Have it enabled will keep synchronized copy of your messages exchanged using \(account.domain) from the last week on this device and allow you to easily view your converstation history.
""";
                controller.onSkip = {
                    controller.dismiss(animated: true, completion: onNext);
                }
                controller.onEnable = { (handler) in
                    AccountSettings.messageSyncPeriod(account).set(double: 24 * 7);
                    AccountSettings.messageSyncAuto(account).set(bool: true);
                    
                    MessageEventHandler.syncMessages(for: account, since: Date().addingTimeInterval(-1 * 24 * 7 * 60 * 60));
                    
                    controller.dismiss(animated: true, completion: onNext);
                }

                completionHandler([controller]);
            }
        }
    }
    
    class PushSuggestion: NewFeaturesDetectorSuggestion {
        
        let feature = PushNotificationsModule.PUSH_NOTIFICATIONS_XMLNS;
        
        func isCapable(_ feature: String) -> Bool {
            return self.feature == feature;
        }
        
        func handle(xmppService: XmppService, account: BareJID, newServerFeatures features: [String], onNext: @escaping ()->Void, completionHandler: @escaping ([NewFeatureSuggestionView])->Void) {
            guard features.contains(feature) else {
                completionHandler([]);
                return;
            }
            
            guard let _: SiskinPushNotificationsModule = xmppService.getClient(forJid: account)?.modulesManager.getModule(SiskinPushNotificationsModule.ID), PushEventHandler.instance.deviceId != nil else {
                completionHandler([]);
                return;
            }
            
            guard !(AccountManager.getAccount(for: account)?.pushNotifications ?? true) else {
                completionHandler([]);
                return;
            }
            
            DispatchQueue.main.async {
                let controller = UIStoryboard(name: "Main", bundle: Bundle.main).instantiateViewController(withIdentifier: "NewFeatureSuggestionView") as! NewFeatureSuggestionView;
                
                _ = controller.view;

                controller.titleField.text = "Push Notifications";
                controller.iconField.image = UIImage(named: "pushNotifications")
                controller.descriptionField.text = """
Your server for account \(account) supports push notifications.
                
With this feature enabled Tigase iOS Messenger can be automatically notified about new messages when it is in background or stopped. Notifications about new messages will be forwarded to our push component and delivered to the device. These notifications will contain message senders jid and part of a message.
""";
                controller.onSkip = {
                    controller.dismiss(animated: true, completion: onNext);
                }
                controller.onEnable = { (handler) in
                    self.enablePush(xmppService: xmppService, account: account, operationFinished: handler, completionHandler: {
                        controller.dismiss(animated: true, completion: onNext);
                    });
                };
                
                completionHandler([controller]);
            }
        }
        
        func enablePush(xmppService: XmppService, account accountJid: BareJID, operationFinished: @escaping ()->Void, completionHandler: @escaping ()->Void) {
            guard let pushModule: SiskinPushNotificationsModule = xmppService.getClient(forJid: accountJid)?.modulesManager.getModule(SiskinPushNotificationsModule.ID), let deviceId = PushEventHandler.instance.deviceId else {
                completionHandler();
                return;
            }
            
            
            pushModule.registerDeviceAndEnable(deviceId: deviceId, pushkitDeviceId: PushEventHandler.instance.pushkitDeviceId) { (result) in
                switch result {
                case .success(_):
                    DispatchQueue.main.async {
                        operationFinished();
                        completionHandler();
                    }
                case .failure(_):
                    DispatchQueue.main.async {
                        operationFinished();
                        self.showError(title: "Push Notifications Error", message: "Server \(accountJid.domain) returned an error on the request to enable push notifications. You can try to enable this feature later on from the account settings.");
                    }
                }
            }
        }
        
    }
}

protocol NewFeaturesDetectorSuggestion: class {
    
    func handle(xmppService: XmppService, account: BareJID, newServerFeatures features: [String], onNext: @escaping ()->Void, completionHandler: @escaping ([NewFeatureSuggestionView])->Void);
    
    func isCapable(_ feature: String) -> Bool;
    
}

extension NewFeaturesDetectorSuggestion {
    
    func showError(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: message, preferredStyle: UIAlertController.Style.alert);
            
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil));
            
            let rootViewController = UIApplication.shared.keyWindow?.rootViewController;
            self.visibleViewController(rootViewController: rootViewController)?.present(alert, animated: true, completion: nil);
        }
    }
    
    func visibleViewController(rootViewController: UIViewController?) -> UIViewController? {
        guard let presentedViewController = rootViewController?.presentedViewController else {
            return rootViewController;
        }
        if let navController = presentedViewController as? UINavigationController {
            return navController.viewControllers.last;
        } else if let tabController = presentedViewController as? UITabBarController {
            return tabController.selectedViewController;
        } else {
            return visibleViewController(rootViewController: presentedViewController);
        }
    }
    
}

class NewFeatureSuggestionView: UIViewController {
    
    @IBOutlet var titleField: UILabel!;
    @IBOutlet var iconField: UIImageView!;
    @IBOutlet var descriptionField: UILabel!;
    @IBOutlet var enableButton: UIButton!;
    @IBOutlet var cancelButton: UIButton!;
    @IBOutlet var progressIndicator: UIActivityIndicatorView!;
    
    var onEnable: ((@escaping ()->Void)->Void)?;
    var onSkip: (()->Void)?;
 
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated);
    }
    
    @IBAction func enableClicked(_ sender: UIButton) {
        self.progressIndicator.startAnimating();
        self.enableButton.isEnabled = false;
        onEnable!(self.onCompleted);
    }
    
    @IBAction func skipClicked(_ sender: UIButton) {
        onSkip!();
    }
    
    func onCompleted() {
        self.enableButton.isEnabled = true;
        self.progressIndicator.stopAnimating();
    }
}
