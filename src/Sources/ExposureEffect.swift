//
//  ExposureEffect.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  What a change to one direction of an app does to its `JackMoebius for <App>` card.
//  The exposure panel shows it *before* the user applies, so a card that is rebuilt (the app
//  sees its device disappear and come back) is never a surprise.
//

import Foundation

/// The effect on the app's dedicated card of switching one direction (input or output) to a new
/// backing / channel count. Mirrors the table of the JackMoebius IPC contract (`jack_add`).
nonisolated enum ExposureEffect: Equatable {
    /// A card is created (the app had none).
    case created
    /// The card is rebuilt with this direction added: the app sees its device go and come back.
    case recreatedAddingSide
    /// The card stays, without this direction (the other direction keeps it): the app still sees
    /// the device, but this direction is no longer wired to it.
    case keptWithoutSide
    /// The card is deleted (this was its only direction).
    case deleted
    /// The card is rebuilt with another channel count.
    case recreatedWidth(Int)

    /// The effect of moving `isInput`'s direction of `app` to `new`, or `nil` when the card is not
    /// touched. A direction counts as holding a card when it is dedicated **and** exposed or still
    /// reserved: the daemon keeps a card for a direction that was only switched off.
    static func compute(app: JackMoebiusApp, isInput: Bool, new: JMSide) -> ExposureEffect? {
        let exposed = isInput ? app.inExposed : app.outExposed
        let width   = isInput ? app.inWidth   : app.outWidth
        let current = isInput ? app.currentIn : app.currentOut
        let was     = (exposed || width > 0) ? current : JMSide.sharedStereo

        let otherExposed = isInput ? app.outExposed : app.inExposed
        let otherWidth   = isInput ? app.outWidth   : app.inWidth
        let otherBacking = isInput ? app.outBacking : app.inBacking
        let otherHasCard = otherBacking == .dedicated && (otherExposed || otherWidth > 0)

        switch (was.backing, new.backing) {
        case (.shared, .dedicated):
            return otherHasCard ? .recreatedAddingSide : .created
        case (.dedicated, .shared):
            return otherHasCard ? .keptWithoutSide : .deleted
        case (.dedicated, .dedicated):
            return was.channels != new.channels ? .recreatedWidth(new.channels) : nil
        case (.shared, .shared):
            return nil
        }
    }
}
