# Retour d'experience - Restauration Windows Image Backup vers QEMU

## Contexte

Tentative de restauration d'un Windows Image Backup (3 fichiers VHDX : boot, windows, recovery) vers un disque QEMU bootable sur macOS. L'objectif etait de faire tourner la machine de Pascal (Windows 10) en VM sur Mac.

## Ce qui a marche

### Construction du disque qcow2 (build_qemu_bootable.sh)
- Conversion VHDX -> qcow2 -> raw -> assemblage MBR -> qcow2 final
- Copie sparse via Python pour economiser l'espace disque (91 Go ecrits sur 466 Go)
- Table MBR avec 3 partitions : Boot (549M), Windows (464.7G), Recovery (533M)
- Le disque a ete cree avec succes (64 Go sur disque, 466 Go virtuel)

### Reparation du BCD
- Erreur initiale : 0xc000000e sur winload.exe (references BCD cassees apres conversion GPT -> MBR)
- `bootrec /fixmbr` : OK
- `bootrec /fixboot` : "Acces refuse" (bug connu Windows 10, pas bloquant)
- `bootrec /rebuildbcd` : a fonctionne, Windows detecte et BCD reconstruit
- `bcdboot D:\Windows /s C: /l fr-fr` : recree les fichiers de demarrage

### Boot QEMU depuis le CD
- `-boot once=d` avec `-cdrom` est la combinaison qui marche
- Les autres options (`-boot order=d`, `-boot d,strict=on`, `-boot menu=on`) ne fonctionnaient pas de maniere fiable

## Ce qui n'a pas marche

### Ruches de registre corrompues
- Apres le boot, erreur 0xc0000225 sur `\Windows\system32\config\system`
- SYSTEM : 8 Ko (devrait etre ~15-60 Mo), SOFTWARE : 8 Ko, DEFAULT : 0 octets
- SAM (131 Ko) et SECURITY (65 Ko) etaient valides
- **Cause probable** : la copie sparse a tronque les fichiers de registre. Le script Python copie par blocs de 64 Ko et saute les blocs entierement nuls, mais les fichiers de registre NTFS peuvent etre fragmentes et la copie au niveau partition (pas au niveau fichier) ne garantit pas l'integrite des fichiers individuels.

### Remplacement par des ruches par defaut
- Extraction des ruches par defaut depuis install.wim de l'ISO Windows 10
- `DISM /mount-wim /wimfile:F:\sources\install.wim /index:1 /mountdir:C:\mount`
- Copie des ruches SYSTEM, SOFTWARE, DEFAULT depuis le WIM
- Resultat : Windows affiche le logo mais reste bloque pendant 1h+
- Les ruches par defaut sont trop differentes de l'installation reelle (drivers, services, config hardware)

### Installation Windows par-dessus
- Tentative d'installation propre depuis le CD sur la partition existante
- Erreur 0x80070570 : "fichiers corrompus ou manquants"
- Le disque a trop de problemes d'integrite pour servir de cible d'installation
- Le chkdsk avait deja signale des problemes

### Repair install (mise a niveau in-place)
- Bloquee par le "Rapport de compatibilite" : impossible depuis le CD
- Il faut que Windows tourne d'abord pour lancer setup.exe, cercle vicieux

## Lecons apprises

### QEMU sur macOS
- Utiliser `-drive file=...,format=qcow2,cache=writeback,if=ide` au lieu de `-hda` pour plus de stabilite
- `-boot once=d` pour booter une fois depuis le CD sans changer l'ordre permanent
- `-display cocoa` pour l'affichage natif macOS
- Le clavier Mac AZERTY a des problemes de mapping dans QEMU (tirets, caracteres speciaux)

### Copie sparse et integrite NTFS
- **Probleme fondamental** : copier une partition NTFS au niveau bloc (secteur par secteur) en sautant les blocs nuls peut corrompre des fichiers
- Les fichiers NTFS peuvent contenir des blocs nuls legitimes (sparse files NTFS, fichiers de registre pre-alloues)
- La copie sparse du script Python saute tout bloc de 64 Ko qui est entierement nul, y compris ceux qui font partie de fichiers valides
- Les fichiers de registre Windows (ruches) sont pre-alloues et peuvent contenir de larges zones nulles internes

### Registre Windows
- Les ruches critiques : SYSTEM, SOFTWARE, DEFAULT, SAM, SECURITY
- RegBack est vide sur les versions recentes de Windows 10 (desactive par defaut depuis 1803)
- DISM /restorehealth ne fonctionne pas si le registre est trop corrompu (erreur 193)
- Les ruches par defaut de install.wim sont inutilisables comme remplacement - trop differentes

### Lettres de lecteur en WinRE
- X: = WinRE (RAM disk)
- C: = partition boot (549M, "Reserve au systeme")
- D: = partition Windows (464G)
- E: = partition Recovery (533M, masquee)
- F: = CD-ROM (ISO)
- Ne PAS confondre avec les lettres vues depuis Windows normal

## Prochaines etapes possibles

1. **Disque neuf + recuperation de fichiers** : creer un qcow2 vierge, installer Windows proprement, attacher l'ancien disque en secondaire pour copier les fichiers utilisateur (`Users\guipa`)
2. **Corriger le script de copie** : ne pas sauter les blocs nuls pour les petites partitions (boot), ou utiliser `qemu-img dd` / `dd` direct sans optimisation sparse pour les partitions critiques
3. **Migration Windows.old** : si on arrive a installer, utiliser robocopy + takeown pour recuperer les fichiers, reg load pour lister les applis installees, winget pour reinstaller en masse
4. **Alternative** : monter le qcow2 sur macOS avec qemu-nbd ou libguestfs pour extraire directement les fichiers utilisateur sans passer par une VM Windows
