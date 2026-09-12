-- The "other app": QuickTime Player opens a new movie recording on its
-- currently selected camera (Elgato 4K X on this machine — see README),
-- records for N seconds, saves the result under ~/Movies (QuickTime is
-- sandboxed and refuses other locations) and closes it. `save` produces a
-- .qtpxcomposition package with the raw "Movie Recording.mov" inside.
on run argv
    set secs to 15
    set outPath to ""
    if (count of argv) > 0 then set secs to (item 1 of argv) as integer
    if (count of argv) > 1 then set outPath to item 2 of argv
    set cam to ""
    if (count of argv) > 2 then set cam to item 3 of argv
    tell application "QuickTime Player"
        activate
        set doc to new movie recording
        delay 4
    end tell
    if cam is not "" then
        -- Pick the camera from the record button's device menu (needs Accessibility).
        tell application "System Events" to tell process "QuickTime Player"
            set b to (first button of window 1 whose description is "show capture device selection menu")
            click b
            delay 1
            click menu item cam of menu 1 of b
            delay 3
        end tell
    end if
    tell application "QuickTime Player"
        start doc
        delay secs
        stop doc
    end tell
    -- "Finishing Recording…" is a modal sheet; wait for it to go.
    repeat 30 times
        delay 1
        tell application "System Events" to tell process "QuickTime Player"
            if not (exists (first window whose subrole is "AXDialog")) then exit repeat
        end tell
    end repeat
    tell application "QuickTime Player"
        set d to document 1
        if outPath is not "" then
            try
                save d in POSIX file outPath
            on error e
                log "save failed: " & e
            end try
        end if
        close document 1 saving no
    end tell
    return "quicktime done"
end run
