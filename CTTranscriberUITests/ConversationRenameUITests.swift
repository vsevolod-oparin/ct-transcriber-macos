import XCTest

final class ConversationRenameUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Helpers

    private var sidebar: XCUIElement {
        app.descendants(matching: .any)["conversationList"].firstMatch
    }

    /// Creates a new conversation. Returns the "New Conversation" text in the sidebar.
    @discardableResult
    private func createConversation() -> XCUIElement {
        let newButton = app.toolbars.buttons["newConversationButton"].firstMatch
        XCTAssertTrue(newButton.waitForExistence(timeout: 3))
        newButton.click()

        let title = sidebar.staticTexts["New Conversation"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3),
                      "Expected 'New Conversation' in sidebar")
        return title
    }

    /// Opens rename via context menu on a sidebar element.
    /// Returns the rename text field.
    @discardableResult
    private func openRename(on element: XCUIElement) -> XCUIElement {
        element.rightClick()
        let renameMenuItem = app.menuItems["Rename"]
        XCTAssertTrue(renameMenuItem.waitForExistence(timeout: 2))
        renameMenuItem.click()

        let field = sidebar.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2), "Rename field should appear")
        return field
    }

    // MARK: - Tests

    func testRenameViaContextMenu() throws {
        let titleElement = createConversation()
        let field = openRename(on: titleElement)

        // Select all, type new name, commit with Enter
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("Renamed Title")
        field.typeKey(.return, modifierFlags: [])

        // New title visible in sidebar
        XCTAssertTrue(sidebar.staticTexts["Renamed Title"].waitForExistence(timeout: 2))
    }

    func testRenameCancelViaEscape() throws {
        let titleElement = createConversation()
        let field = openRename(on: titleElement)

        // Type something but cancel with Escape
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("Should not persist")
        field.typeKey(.escape, modifierFlags: [])

        // Original title preserved in sidebar
        XCTAssertTrue(sidebar.staticTexts["New Conversation"].waitForExistence(timeout: 2))
    }

    func testRenameEmptyStringKeepsOriginal() throws {
        let titleElement = createConversation()
        let field = openRename(on: titleElement)

        // Clear all and commit empty
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeKey(.return, modifierFlags: [])

        // Original title preserved (empty string rejected)
        XCTAssertTrue(sidebar.staticTexts["New Conversation"].waitForExistence(timeout: 2))
    }

    /// Creates 3 conversations, renames them one by one with a mix of
    /// commits and cancels, then verifies the final sidebar state.
    func testRenameMultipleConversationsWithMixedCommitAndCancel() throws {
        // Create 3 conversations — they all start as "New Conversation"
        createConversation()
        createConversation()
        createConversation()

        // Rename the first one (top of list = most recent) → commit
        let first = sidebar.staticTexts["New Conversation"].firstMatch
        var field = openRename(on: first)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("Alpha")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForExistence(timeout: 2))

        // Rename the next "New Conversation" → cancel
        let second = sidebar.staticTexts["New Conversation"].firstMatch
        field = openRename(on: second)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("This gets cancelled")
        field.typeKey(.escape, modifierFlags: [])

        // Rename same one again → commit this time
        let secondAgain = sidebar.staticTexts["New Conversation"].firstMatch
        field = openRename(on: secondAgain)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("Beta")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["Beta"].waitForExistence(timeout: 2))

        // Rename the last remaining "New Conversation" → commit
        let third = sidebar.staticTexts["New Conversation"].firstMatch
        field = openRename(on: third)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("Gamma")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["Gamma"].waitForExistence(timeout: 2))

        // Verify final state: all three unique names present, no "New Conversation" left
        XCTAssertTrue(sidebar.staticTexts["Alpha"].exists)
        XCTAssertTrue(sidebar.staticTexts["Beta"].exists)
        XCTAssertTrue(sidebar.staticTexts["Gamma"].exists)
        XCTAssertFalse(sidebar.staticTexts["New Conversation"].exists)
    }

    /// Creates 3 conversations, renames them back and forth —
    /// rename one, switch to another, rename it, go back and rename the first again.
    func testRenameBackAndForthBetweenConversations() throws {
        createConversation()
        createConversation()
        createConversation()

        // Rename first → "AAA"
        var target = sidebar.staticTexts["New Conversation"].firstMatch
        var field = openRename(on: target)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("AAA")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["AAA"].waitForExistence(timeout: 2))

        // Rename second → "BBB"
        target = sidebar.staticTexts["New Conversation"].firstMatch
        field = openRename(on: target)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("BBB")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["BBB"].waitForExistence(timeout: 2))

        // Go back to "AAA" and rename to "AAA-v2"
        target = sidebar.staticTexts["AAA"].firstMatch
        field = openRename(on: target)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("AAA-v2")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["AAA-v2"].waitForExistence(timeout: 2))
        XCTAssertFalse(sidebar.staticTexts["AAA"].exists)

        // Try renaming "BBB" but cancel
        target = sidebar.staticTexts["BBB"].firstMatch
        field = openRename(on: target)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("BBB-nope")
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["BBB"].waitForExistence(timeout: 2))
        XCTAssertFalse(sidebar.staticTexts["BBB-nope"].exists)

        // Rename last "New Conversation" → "CCC"
        target = sidebar.staticTexts["New Conversation"].firstMatch
        field = openRename(on: target)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("CCC")
        field.typeKey(.return, modifierFlags: [])

        // Final state
        XCTAssertTrue(sidebar.staticTexts["AAA-v2"].exists)
        XCTAssertTrue(sidebar.staticTexts["BBB"].exists)
        XCTAssertTrue(sidebar.staticTexts["CCC"].exists)
        XCTAssertFalse(sidebar.staticTexts["New Conversation"].exists)
    }
}
