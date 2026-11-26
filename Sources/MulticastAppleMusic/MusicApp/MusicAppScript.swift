#if os(macOS)
import Foundation

/// The AppleScript that `MusicAppPlayer` compiles once and calls handler by handler (parameters
/// travel as Apple Event descriptors, never pasted into source, so no quoting issues).
///
/// Every handler assumes Music is running; `MusicAppPlayer` checks (and launches it in the
/// background when its policy allows) before calling, because `tell application` would
/// otherwise launch it in the foreground.
///
/// Results are plain lists so they parse without terminology:
///  - track columns: `{ids, names, artists, albums, durations}` (parallel lists)
///  - playlists: `{{id, name, trackCount, firstTrackID}, …}`
///  - state: `{stateText, shuffle, volume, position, {id, name, artist, album, duration} | {}}`
///  - up next: `{"ok", remaining, ids, names, artists, albums, durations}` or `{"stopped"|"shuffled"|"unknown"}`
enum MusicAppScript {
    static let source = """
    on librarycount()
        tell application id "com.apple.Music" to return count of tracks of library playlist 1
    end librarycount

    on librarytracks()
        tell application id "com.apple.Music"
            set lp to library playlist 1
            if (count of tracks of lp) is 0 then return {{}, {}, {}, {}, {}}
            return {persistent ID of every track of lp, name of every track of lp, artist of every track of lp, album of every track of lp, duration of every track of lp}
        end tell
    end librarytracks

    on playlistlist()
        tell application id "com.apple.Music"
            set out to {}
            repeat with p in (get every user playlist)
                try
                    if special kind of p is none then
                        set c to count of tracks of p
                        set f to ""
                        if c > 0 then set f to persistent ID of track 1 of p
                        set end of out to {persistent ID of p, name of p, c, f}
                    end if
                end try
            end repeat
            return out
        end tell
    end playlistlist

    on playlisttracks(pid)
        tell application id "com.apple.Music"
            set p to first user playlist whose persistent ID is pid
            if (count of tracks of p) is 0 then return {{}, {}, {}, {}, {}}
            return {persistent ID of every track of p, name of every track of p, artist of every track of p, album of every track of p, duration of every track of p}
        end tell
    end playlisttracks

    on playtrack(tid, pid)
        tell application id "com.apple.Music"
            if pid is "" then
                set t to first track of library playlist 1 whose persistent ID is tid
            else
                set p to first user playlist whose persistent ID is pid
                set t to first track of p whose persistent ID is tid
            end if
            play t
        end tell
        return "OK"
    end playtrack

    on playincurrent(tid)
        tell application id "com.apple.Music"
            set t to first track of current playlist whose persistent ID is tid
            play t
        end tell
        return "OK"
    end playincurrent

    on playplaylist(pid, shuffled)
        tell application id "com.apple.Music"
            set p to first user playlist whose persistent ID is pid
            set shuffle enabled to shuffled
            play p
        end tell
        return "OK"
    end playplaylist

    on transport(cmd, pos)
        tell application id "com.apple.Music"
            if cmd is "play" then
                play
            else if cmd is "pause" then
                pause
            else if cmd is "next" then
                next track
            else if cmd is "previous" then
                previous track
            else if cmd is "seek" then
                set player position to pos
            else if cmd is "stop" then
                stop
            end if
        end tell
        return "OK"
    end transport

    on playerstate()
        tell application id "com.apple.Music"
            set pstate to (player state as text)
            set shuf to false
            try
                set shuf to shuffle enabled
            end try
            set vol to sound volume
            set ppos to -1
            try
                set ppos to player position
            end try
            set info to {}
            try
                set t to current track
                set d to 0
                try
                    set d to duration of t
                end try
                set info to {persistent ID of t, name of t, artist of t, album of t, d}
            end try
            return {pstate, shuf, vol, ppos, info}
        end tell
    end playerstate

    on upnext(s, e)
        tell application id "com.apple.Music"
            if player state is stopped then return {"stopped"}
            if shuffle enabled then return {"shuffled"}
            try
                set cp to current playlist
                set idx to index of current track
                set n to count of tracks of cp
            on error
                return {"unknown"}
            end try
            set a to idx + s
            set b to idx + e
            if b > n then set b to n
            if a > b then return {"ok", n - idx, {}, {}, {}, {}, {}}
            return {"ok", n - idx, persistent ID of tracks a thru b of cp, name of tracks a thru b of cp, artist of tracks a thru b of cp, album of tracks a thru b of cp, duration of tracks a thru b of cp}
        end tell
    end upnext

    on airplayelsewhere()
        tell application id "com.apple.Music"
            set c to 0
            try
                repeat with d in (get current AirPlay devices)
                    if kind of d is not computer then set c to c + 1
                end repeat
            end try
            return c
        end tell
    end airplayelsewhere

    on getvolume()
        tell application id "com.apple.Music" to return sound volume
    end getvolume

    on setvolume(v)
        tell application id "com.apple.Music" to set sound volume to v
        return "OK"
    end setvolume

    on artworkdata(tid)
        tell application id "com.apple.Music"
            set t to first track of library playlist 1 whose persistent ID is tid
            if (count of artworks of t) is 0 then return ""
            return raw data of artwork 1 of t
        end tell
    end artworkdata
    """
}
#endif
