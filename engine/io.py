"""Terminal input and output for a conversation."""

import sys


class Terminal:
    def __init__(self, quiet=False):
        self.quiet = quiet
        self.open = False

    def read(self):
        """The user's next line, or None at end of input."""
        try:
            line = input("\nyou: ")
        except EOFError:
            print()
            return None
        return line

    def start_turn(self):
        sys.stdout.write("\n")
        sys.stdout.flush()
        self.open = False

    def delta(self, text):
        if not self.open:
            sys.stdout.write("assistant: ")
            self.open = True
        sys.stdout.write(text)
        sys.stdout.flush()

    def end_turn(self):
        if self.open:
            sys.stdout.write("\n")
            sys.stdout.flush()
            self.open = False

    def note(self, text):
        if self.quiet:
            return
        if self.open:
            sys.stdout.write("\n")
            self.open = False
        sys.stdout.write(f"  [{text}]\n")
        sys.stdout.flush()

    def close(self):
        pass
