import os
import re
import sys

truth_values = ("true", "yes", "1")
env_flag_re = re.compile(r"^# ?env: ?(BENTO[A-Z_]+)")

fl = next(sys.stdin, "")

if match := env_flag_re.match(fl):  # if we found a flag to check, make sure it's true
    env_var = match.group(1)
    val = os.getenv(env_var)
    print(str(val is not None and val in truth_values).lower())
else:
    print("true")  # otherwise, always enable
