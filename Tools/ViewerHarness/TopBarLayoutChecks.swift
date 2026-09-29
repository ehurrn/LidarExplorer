//
//  TopBarLayoutChecks.swift
//  ViewerHarness
//
//  The top bar's layout (TopBarLayout): the buttons' gap from the room the bar has, the readout on the first row or
//  its own, and the window controls of an iPad app in a window. Widths are the bar's inside its 16 pt margins; the
//  buttons are 320 pt without their gaps (three 44 pt circles and the cluster's 4 × 46 + 4). The corner is what the
//  Simulator reported for the controls (iPadOS 27, iPad Pro 13-inch): 66 × 75 pt from the bar's top-leading corner,
//  so 50 × 67 from its content's, and the bar keeps 8 pt clear of it: 58 pt of the first row.
//

import CoreGraphics
import Foundation

@MainActor
func runTopBarLayoutChecks() {
    print("\n=== Top bar layout ===")
    checkTopBarLayout()
    checkTopBarSource()
}

@MainActor
private func checkTopBarLayout() {
    print("\n--- Y1. the buttons' gap, one row or two, and the window controls ---")
    let buttons: CGFloat = 320, readable: CGFloat = 220
    let corner = CGSize(width: 50, height: 67)
    func layout(_ width: CGFloat?, _ controls: CGSize = .zero) -> TopBarLayout {
        TopBarLayout(barWidth: width, buttonsWidth: buttons, readableReadoutWidth: readable, windowControls: controls)
    }
    func describe(_ l: TopBarLayout) -> String {
        "gap \(l.controlsSpacing), row \(l.controlsWidth), one row \(l.fitsOneRow), overflow \(l.controlsOverflow), "
            + "readout inset \(l.readoutLeadingInset), drop \(l.topInset)"
    }

    let unmeasured = layout(nil)
    check("before the bar is measured: 10 pt gaps, one row, no overflow and nothing moved",
          unmeasured.controlsSpacing == 10 && unmeasured.fitsOneRow && !unmeasured.controlsOverflow
              && unmeasured.readoutLeadingInset == 0 && unmeasured.topInset == 0, describe(unmeasured))

    let fullScreen = layout(1000)
    check("a 13-inch iPad in portrait, full screen (1000 pt): 10 pt gaps (350 pt), one row, nothing moved",
          fullScreen.controlsSpacing == 10 && fullScreen.controlsWidth == 350 && fullScreen.fitsOneRow
              && fullScreen.readoutLeadingInset == 0 && fullScreen.topInset == 0, describe(fullScreen))

    let phone375 = layout(343)
    check("a 375 pt phone in portrait (343 pt): 6 pt gaps, the row 338 pt fits, the readout on its own row",
          phone375.controlsSpacing == 6 && phone375.controlsWidth == 338 && !phone375.controlsOverflow
              && !phone375.fitsOneRow, describe(phone375))

    let exact = layout(350)
    check("a bar exactly as wide as the row at 10 pt (350 pt) keeps the 10 pt gaps",
          exact.controlsSpacing == 10 && !exact.controlsOverflow, describe(exact))
    let hairShort = layout(349.5)
    check("half a point short of it (349.5 pt) takes the 6 pt gaps",
          hairShort.controlsSpacing == 6 && !hairShort.controlsOverflow, describe(hairShort))

    // The gap follows the room, not the size class (review of task 7): the class does not say how wide the map column
    // is, which the Map Styles inspector narrows in a regular-width window (to 448 pt at the least in the Simulator).
    let tight = layout(338)
    check("a 338 pt bar, whatever its size class: 6 pt gaps and the row fits exactly",
          tight.controlsSpacing == 6 && !tight.controlsOverflow, describe(tight))
    let tooNarrow = layout(311)
    check("a 311 pt bar, narrower than the row even at 6 pt: overflow, which the bar centres",
          tooNarrow.controlsSpacing == 6 && tooNarrow.controlsOverflow, describe(tooNarrow))

    // One row needs the buttons, the spacer's 8, two 10 pt gaps and 220 pt of readout: 598 pt at 10 pt gaps.
    let oneRowEdge = layout(598), twoRowEdge = layout(597.5)
    check("one row from 598 pt (350 + 28 + 220), two below it",
          oneRowEdge.fitsOneRow && !twoRowEdge.fitsOneRow,
          "\(describe(oneRowEdge)); \(describe(twoRowEdge))")

    // In a window: the controls' corner reaches 50 pt across and 67 down; with the 8 pt gap, 58 pt of the first row.
    let narrowestWindow = layout(343, corner)
    check("the narrowest window (375 pt, 343 inside the margins): the buttons, 338 pt at the row's trailing edge, would "
          + "reach under the window controls, so the bar drops the whole corner, 67 pt, below them",
          !narrowestWindow.fitsOneRow && narrowestWindow.controlsSpacing == 6 && narrowestWindow.topInset == 67
              && narrowestWindow.readoutLeadingInset == 0, describe(narrowestWindow))
    let clearWindow = layout(468, corner)
    check("a 500 pt window (468 pt): two rows, the buttons at the trailing edge clear the controls (118 pt free against "
          + "58), nothing moved", !clearWindow.fitsOneRow && clearWindow.topInset == 0
              && clearWindow.readoutLeadingInset == 0, describe(clearWindow))
    let justClear = layout(408, corner), justUnder = layout(407.5, corner)
    check("the buttons clear the controls and the 8 pt gap with 58 pt free beside them (408 pt at 10 pt gaps), and drop "
          + "with less (the 432 pt window, 400 pt, put the location button 3 pt from the controls' glass)",
          justClear.topInset == 0 && justUnder.topInset == 67,
          "\(describe(justClear)); \(describe(justUnder))")
    let wideWindow = layout(668, corner)
    check("a 700 pt window (668 pt): one row, the readout starting 58 pt in, past the controls and the gap, and no drop",
          wideWindow.fitsOneRow && wideWindow.readoutLeadingInset == 58 && wideWindow.topInset == 0,
          describe(wideWindow))
    let crowded = layout(608, corner), crowdedFullScreen = layout(608)
    check("the controls' corner counts against the readout's room: 608 pt is one row full screen and two in a window",
          crowdedFullScreen.fitsOneRow && !crowded.fitsOneRow && crowded.topInset == 0,
          "\(describe(crowdedFullScreen)); \(describe(crowded))")
    let oneRowInWindow = layout(656, corner), twoRowsInWindow = layout(655.5, corner)
    check("in a window one row needs the corner's 58 pt more: 656 pt, two below it",
          oneRowInWindow.fitsOneRow && !twoRowsInWindow.fitsOneRow,
          "\(describe(oneRowInWindow)); \(describe(twoRowsInWindow))")

    // A corner that does not reach the content moves nothing.
    let aboveContent = layout(343, CGSize(width: 50, height: 0))
    let withinMargin = layout(343, CGSize(width: -4, height: 67))
    let atMargin = layout(343, CGSize(width: 0, height: 67))
    let overflowingWithinMargin = layout(311, CGSize(width: -4, height: 67))
    let unreached: [TopBarLayout] = [aboveContent, withinMargin, atMargin, overflowingWithinMargin]
    let nothingMoved = unreached.allSatisfy { l in
        l.topInset == 0 && l.windowControlsReach == 0 && l.readoutLeadingInset == 0
    }
    check("a corner that ends above the content, within the leading margin or at its edge, moves nothing, even with "
          + "the buttons overflowing the bar", nothingMoved, unreached.map(describe).joined(separator: "; "))
}

/// Reads ViewerTopBarView's source for what the arithmetic above relies on: the view asks TopBarLayout, measures the
/// width it is offered (not a first row the buttons have overflowed), and reads the controls' corner on a frame the
/// drop does not move (a corner read on the moving content would stop reaching it once dropped, and bring it back up).
@MainActor
private func checkTopBarSource() {
    print("\n--- Y2. the top bar view follows TopBarLayout ---")
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../LidarExplorer/Presentation/ViewerTopBarView.swift").standardized.path
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        check("ViewerTopBarView.swift is readable", false, path)
        return
    }
    let code = source.split(separator: "\n").map { line -> String in
        guard let comment = line.range(of: "//") else { return String(line) }
        return String(line[..<comment.lowerBound])
    }.joined(separator: "\n")

    check("the view builds its layout from TopBarLayout", code.contains("TopBarLayout("))
    check("the buttons' gap no longer follows the size class", !code.contains("horizontalSizeClass"))
    check("the first row reports the width it is offered, not the buttons' when they overflow (minWidth: 0)",
          code.contains(".frame(minWidth: 0, maxWidth: .infinity"))
    if let drop = code.range(of: ".padding(.top, layout.topInset)"),
       let margins = code.range(of: ".padding(.horizontal, ", range: drop.upperBound..<code.endIndex),
       let corner = code.range(of: "containerCornerInsets.topLeading", range: margins.upperBound..<code.endIndex) {
        check("the controls' corner is read outside the drop and the margins, on a frame neither moves",
              corner.lowerBound > margins.upperBound && margins.lowerBound > drop.upperBound)
    } else {
        check("the controls' corner is read outside the drop and the margins, on a frame neither moves", false,
              "expected .padding(.top, layout.topInset), then .padding(.horizontal, …), then containerCornerInsets.topLeading")
    }
}
