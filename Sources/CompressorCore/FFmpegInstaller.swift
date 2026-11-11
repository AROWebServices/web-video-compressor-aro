import Foundation

/// The shell script behind the app's "Install FFmpeg" button. It runs in
/// Terminal because Homebrew's installer asks for the Mac password and shows
/// its own progress.
public enum FFmpegInstaller {
    public static let homebrewInstallURL = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

    public static func script(appName: String) -> String {
        """
        #!/bin/bash
        # Installs Homebrew (only if it is missing) and then FFmpeg.
        find_brew() {
            for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                if [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
            done
            return 1
        }
        fail() {
            echo
            echo "FFmpeg was not installed: $1"
            echo "You can close this window and try again from \(appName)."
            exit 1
        }

        clear
        echo "\(appName): setting up FFmpeg"
        echo

        BREW="$(find_brew)"
        if [ -z "$BREW" ]; then
            echo "Homebrew is not installed yet. Installing it first."
            echo "It will ask for your Mac password and may take several minutes."
            echo
            /bin/bash -c "$(curl -fsSL \(homebrewInstallURL))" || fail "the Homebrew installer stopped."
            BREW="$(find_brew)" || fail "Homebrew could not be found after installing."
        else
            echo "Homebrew is already installed."
        fi

        echo
        echo "Installing FFmpeg. This can take a few minutes."
        echo
        "$BREW" install ffmpeg || fail "Homebrew could not install it."

        BIN="$(dirname "$BREW")"
        if [ -x "$BIN/ffmpeg" ] && [ -x "$BIN/ffprobe" ]; then
            echo
            echo "FFmpeg is ready. Close this window and go back to \(appName)."
        else
            fail "ffmpeg and ffprobe are not in $BIN."
        fi
        """
    }
}
