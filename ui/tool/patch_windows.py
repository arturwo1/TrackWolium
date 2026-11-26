import re
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1])
icon = Path(sys.argv[2])
runner = root / "windows" / "runner"

shutil.copy(icon, runner / "resources" / "app_icon.ico")

main_cpp = runner / "main.cpp"
text = main_cpp.read_text(encoding="utf-8")
text = re.sub(r'(window\.Create\(L")[^"]*(")', r"\1Wolium\2", text)
main_cpp.write_text(text, encoding="utf-8")

rc = runner / "Runner.rc"
text = rc.read_text(encoding="utf-8", errors="ignore")
for key, value in (("CompanyName", "DTSys"), ("FileDescription", "Wolium"), ("ProductName", "Wolium"),
                   ("InternalName", "wolium"), ("LegalCopyright", "DTSys")):
    text = re.sub(r'(VALUE "%s", )"[^"]*"' % key, r'\1"%s"' % value, text)
rc.write_text(text, encoding="utf-8")

win32 = runner / "win32_window.cpp"
if win32.exists():
    wtext = win32.read_text(encoding="utf-8")
    wtext = wtext.replace(
        "ShowWindow(window_handle_, SW_SHOWNORMAL);",
        "ShowWindow(window_handle_, IsZoomed(window_handle_) ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);",
    )
    win32.write_text(wtext, encoding="utf-8")

