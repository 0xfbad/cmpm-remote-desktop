#!/usr/bin/python3
import os
import signal
import sys

from prompt_toolkit import PromptSession
from prompt_toolkit.history import DummyHistory
from prompt_toolkit.input import create_input
from prompt_toolkit.output import create_output

parent_pid = os.getppid()
try:
    parent_is_ssh = os.readlink(f'/proc/{parent_pid}/exe') == '/usr/bin/ssh'
except OSError:
    parent_is_ssh = False

try:
    with open('/dev/tty', 'r') as tty_in, open('/dev/tty', 'w') as tty_out:
        if os.environ.get('SSH_ASKPASS_PROMPT') == 'none':
            print(sys.argv[1], file=tty_out)
            raise SystemExit()
        tty_input = create_input(stdin=tty_in)
        try:
            session = PromptSession(input=tty_input, output=create_output(stdout=tty_out), history=DummyHistory())
            response = session.prompt(sys.argv[1], is_password=True, enable_suspend=True)
        finally:
            tty_input.close()
except KeyboardInterrupt:
    if parent_is_ssh:
        try:
            os.kill(parent_pid, signal.SIGINT)  # helper failure alone makes ssh retry
        except ProcessLookupError:
            pass
    raise SystemExit(1)
except EOFError:
    raise SystemExit(1)
except OSError:
    print('SSH password input requires a terminal.', file=sys.stderr)
    raise SystemExit(1)
print(response)
