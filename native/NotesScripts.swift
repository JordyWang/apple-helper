import Foundation

// Fixed source only. All user strings are passed as typed Apple-event parameters.
enum NotesScripts {
    static let source = #"""
    on accountRows()
        tell application "Notes"
            set rows to {}
            set defaultID to id of default account
            repeat with a in accounts
                set end of rows to {id of a, name of a, upgraded of a, id of default folder of a, (id of a is defaultID)}
            end repeat
            return rows
        end tell
    end accountRows

    on folderRow(f)
        tell application "Notes"
            set parentObject to get container of f
            set parentID to id of parentObject
            set topLevel to class of parentObject is account
            set a to parentObject
            repeat 100 times
                if class of a is account then exit repeat
                set a to get container of a
            end repeat
            return {id of f, name of f, parentID, topLevel, id of a, shared of f, id of every note of f, id of every folder of f}
        end tell
    end folderRow

    on folderRows()
        tell application "Notes" to set fs to every folder
        set rows to {}
        repeat with f in fs
            try
                set end of rows to my folderRow(contents of f)
            on error errorMessage number errorNumber
                if errorNumber is not -1728 then error errorMessage number errorNumber
            end try
        end repeat
        return rows
    end folderRows

    on readFolder(folderID)
        tell application "Notes" to set f to folder id folderID
        return my folderRow(f)
    end readFolder

    on noteMetadata(n)
        tell application "Notes"
            set f to get container of n
            return {id of n, name of n, id of f, creation date of n, modification date of n, password protected of n, shared of n}
        end tell
    end noteMetadata

    on readMetadata(noteID)
        tell application "Notes" to set n to note id noteID
        return my noteMetadata(n)
    end readMetadata

    on noteRows(folderID, accountID, searchText, searchBody)
        tell application "Notes"
            if folderID is not "" then
                set candidateCount to count of notes of folder id folderID
                if searchText is not "" and not searchBody then
                    set ns to every note of folder id folderID whose name contains searchText
                else
                    set ns to every note of folder id folderID
                end if
            else if accountID is not "" then
                set candidateCount to count of notes of account id accountID
                if searchText is not "" and not searchBody then
                    set ns to every note of account id accountID whose name contains searchText
                else
                    set ns to every note of account id accountID
                end if
            else
                set candidateCount to count of notes
                if searchText is not "" and not searchBody then
                    set ns to every note whose name contains searchText
                else
                    set ns to every note
                end if
            end if
            if candidateCount > 2000 then error "Narrow the folder/account scope; more than 2000 candidate notes." number 7101
            set rows to {}
            repeat with n in ns
              try
                set matches to true
                if searchText is not "" then
                    if searchBody then
                        if password protected of n then
                            set matches to false
                        else
                            ignoring case
                                set matches to (plaintext of n contains searchText)
                            end ignoring
                        end if
                    else
                        ignoring case
                            set matches to (name of n contains searchText)
                        end ignoring
                    end if
                end if
                if matches then set end of rows to my noteMetadata(contents of n)
              on error errorMessage number errorNumber
                if errorNumber is not -1728 then error errorMessage number errorNumber
              end try
            end repeat
            return rows
        end tell
    end noteRows

    on readNote(noteID)
        tell application "Notes"
            set n to note id noteID
            set info to my noteMetadata(n)
            if password protected of n then return {info, "", "", {}}
            set attachmentRows to {}
            set attachmentIDs to get id of every attachment of n
            repeat with attachmentID in attachmentIDs
                try
                    set a to attachment id (contents of attachmentID) of n
                    set end of attachmentRows to {id of a, name of a, content identifier of a, creation date of a, modification date of a}
                on error errorMessage number errorNumber
                    if errorNumber is -1728 or errorNumber is -1719 then error "Notes attachments changed during the read." number -1719
                    error errorMessage number errorNumber
                end try
            end repeat
            return {info, body of n, plaintext of n, attachmentRows}
        end tell
    end readNote

    on makeNote(folderID, html)
        tell application "Notes"
            set n to make new note at folder id folderID with properties {body:html}
            return id of n
        end tell
    end makeNote

    on changeNote(noteID, changeTitle, newTitle, changeBody, html)
        tell application "Notes"
            if changeBody then set body of note id noteID to html
            if changeTitle then set name of note id noteID to newTitle
            return noteID
        end tell
    end changeNote

    on moveNote(noteID, folderID)
        tell application "Notes" to move note id noteID to folder id folderID
        return noteID
    end moveNote

    on removeNote(noteID)
        tell application "Notes" to delete note id noteID
        return true
    end removeNote

    on makeFolder(parentID, parentIsAccount, folderName)
        tell application "Notes"
            if parentIsAccount then
                set f to make new folder at account id parentID with properties {name:folderName}
            else
                set f to make new folder at folder id parentID with properties {name:folderName}
            end if
            return id of f
        end tell
    end makeFolder

    on renameFolder(folderID, folderName)
        tell application "Notes" to set name of folder id folderID to folderName
        return folderID
    end renameFolder

    on removeFolder(folderID)
        tell application "Notes" to delete folder id folderID
        return true
    end removeFolder
    """#
}
