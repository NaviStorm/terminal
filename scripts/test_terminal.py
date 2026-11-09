import os, re, select, termios, time, tty

# Les requêtes et leurs réponses passent par le terminal actif.
fd = os.open("/dev/tty", os.O_RDWR)
initial = termios.tcgetattr(fd)

def tester(nom, requete, motif, description):
    os.write(fd, requete)
    reponse = b""
    limite = time.monotonic() + 2
    while True:
        match = re.fullmatch(motif, reponse)
        if match:
            valeurs = [int(groupe) for groupe in match.groups()]
            return f"{nom} : {description.format(*valeurs)}"
        reste = limite - time.monotonic()
        if reste <= 0 or not select.select([fd], [], [], reste)[0]:
            if not reponse:
                return f"{nom} : aucune réponse après 2 secondes"
            return f"{nom} : réponse inattendue {reponse!r}"
        reponse += os.read(fd, 128)

try:
    tty.setraw(fd)
    resultats = [
        tester("Identité", b"\x1b[c",   rb"\x1b\[\?1;2c", "compatible VT100, option vidéo avancée"),
        tester("État",     b"\x1b[5n",  rb"\x1b\[0n", "terminal prêt"),
        tester("Curseur",  b"\x1b[6n",  rb"\x1b\[([1-9]\d*);([1-9]\d*)R", "ligne {}, colonne {}"),
        tester("Grille",   b"\x1b[18t", rb"\x1b\[8;([1-9]\d*);([1-9]\d*)t", "{} lignes × {} colonnes"),
    ]
finally:
    termios.tcsetattr(fd, termios.TCSANOW, initial)
    os.close(fd)

print(*resultats, sep="\n")
