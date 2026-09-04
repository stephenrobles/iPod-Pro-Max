//
//  MusicDownloader.swift
//  iPod Pro Max
//
//  Asks the Music app to download iCloud tracks (its AppleScript `download` command), so songs that
//  live only in iCloud can be made syncable without leaving iPod Pro Max.
//

import Foundation
import AppKit

enum MusicPID {
    /// Music's AppleScript persistent IDs are 16 uppercase hex digits; iTunesLibrary gives an unpadded number.
    static func normalize(_ s: String) -> String {
        let up = s.uppercased()
        return up.count >= 16 ? up : String(repeating: "0", count: 16 - up.count) + up
    }
}

enum MusicDownloader {
    struct Result {
        var requested = 0
        var notFound = 0
        var errorMessage: String?
    }

    /// Triggers downloads in Music for the given persistent ids. Runs on the main thread (NSAppleScript requirement).
    @MainActor
    static func download(persistentIDs: [String]) -> Result {
        var result = Result()
        guard !persistentIDs.isEmpty else { return result }
        let list = persistentIDs.map { "\"\(MusicPID.normalize($0))\"" }.joined(separator: ", ")
        let source = """
        set pids to {\(list)}
        set found to 0
        set missing to 0
        tell application "Music"
            set lib to library playlist 1
            repeat with pid in pids
                try
                    set matches to (every track of lib whose persistent ID is (pid as string))
                    if (count of matches) > 0 then
                        download (item 1 of matches)
                        set found to found + 1
                    else
                        set missing to missing + 1
                    end if
                on error errMsg
                    set missing to missing + 1
                end try
            end repeat
        end tell
        return (found as string) & "," & (missing as string)
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            result.errorMessage = "Couldn't build the Music script."
            return result
        }
        let output = script.executeAndReturnError(&error)
        if let error {
            let msg = (error[NSAppleScript.errorMessage] as? String) ?? "Music didn't respond."
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 {
                result.errorMessage = "iPod Pro Max isn't allowed to control Music. Allow it in System Settings › Privacy & Security › Automation, then try again."
            } else {
                result.errorMessage = msg
            }
            return result
        }
        let parts = (output.stringValue ?? "").split(separator: ",").compactMap { Int($0) }
        if parts.count == 2 {
            result.requested = parts[0]
            result.notFound = parts[1]
        }
        return result
    }
}
