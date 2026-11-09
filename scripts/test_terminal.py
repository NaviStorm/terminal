import os, re, select, termios, time, tty

# Les requêtes et leurs réponses passent par le terminal actif.
fd = os.open("/dev/tty", os.O_RDWR)
initial = termios.tcgetattr(fd)

def tester(nom, requete, motif):
    os.write(fd, requete)
    reponse = b""
    limite = time.monotonic() + 2
    while not re.fullmatch(motif, reponse):
        reste = limite - time.monotonic()
        if reste <= 0 or not select.select([fd], [], [], reste)[0]:
            return f"ÉCHEC — {nom} : {reponse!r}"
        reponse += os.read(fd, 128)
    return f"OK — {nom} : {reponse!r}"

try:
    tty.setraw(fd)
    resultats = [
        tester("Identité", b"\x1b[c",   rb"\x1b\[\?1;2c"),
        tester("État",     b"\x1b[5n",  rb"\x1b\[0n"),
        tester("Curseur",  b"\x1b[6n",  rb"\x1b\[[1-9]\d*;[1-9]\d*R"),
        tester("Grille",   b"\x1b[18t", rb"\x1b\[8;[1-9]\d*;[1-9]\d*t"),
    ]
finally:
    termios.tcsetattr(fd, termios.TCSANOW, initial)
    os.close(fd)

print(*resultats, sep="\n")
