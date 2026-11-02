import base64, json, re, subprocess, sys
REPOS = """jesseduffield/lazygit charmbracelet/gum charmbracelet/vhs charmbracelet/glow charmbracelet/crush
atuinsh/atuin ajeetdsouza/zoxide junegunn/fzf sharkdp/bat starship/starship sxyazi/yazi aristocratos/btop
derailed/k9s yorukot/superfile darrenburns/posting tconbeer/harlequin jordanbaird/Ice rxhanson/Rectangle
p0deje/Maccy MrKai77/Loop nikitabobko/AeroSpace manaflow-ai/cmux ghostty-org/ghostty zed-industries/zed
warpdotdev/Warp sst/opencode openai/codex anthropics/claude-code smtg-ai/claude-squad stablyai/orca
BloopAI/vibe-kanban wandb/catnip dlvhdr/gh-dash jesseduffield/lazydocker""".split()
rows=[]
for r in REPOS:
    try:
        d=json.loads(subprocess.run(["gh","api",f"repos/{r}/readme"],capture_output=True,text=True,check=True).stdout)
        md=base64.b64decode(d["content"]).decode("utf-8","replace")
        info=json.loads(subprocess.run(["gh","api",f"repos/{r}","--jq","{stars:.stargazers_count}"],capture_output=True,text=True).stdout)
    except Exception as e:
        print(r,"ERR",e,file=sys.stderr); continue
    lines=md.splitlines()
    media=[]
    for i,l in enumerate(lines):
        for m in re.finditer(r'(?:src=["\']|\]\()([^"\')\s]+)',l):
            u=m.group(1); ul=u.lower()
            if "shields.io" in ul or "badge" in ul or "/actions/" in ul: continue
            kind = "gif" if ".gif" in ul else "video" if re.search(r'\.(mp4|mov|webm)|user-attachments/assets|asciinema',ul) else "img" if re.search(r'\.(png|jpe?g|webp|svg)',ul) else None
            if kind: media.append((i,kind,u))
        if re.match(r'^https://github\.com/user-attachments/assets/\S+$',l.strip()): media.append((i,"video",l.strip()))
    heads=[i for i,l in enumerate(lines) if l.startswith("#")]
    first=media[0] if media else None
    rows.append(dict(repo=r,stars=info.get("stars"),lines=len(lines),
        gif=sum(k=="gif" for _,k,_ in media),video=sum(k=="video" for _,k,_ in media),img=sum(k=="img" for _,k,_ in media),
        first_kind=first[1] if first else "-",first_at=f"{first[0]}/{len(lines)}" if first else "-",
        media=[(i,k,u) for i,k,u in media]))
json.dump(rows,open("scan.json","w"),indent=1)
rows.sort(key=lambda x:-(x["stars"] or 0))
print(f'{"repo":28}{"stars":>7}{"gif":>5}{"vid":>5}{"img":>5}  hero(line)')
for x in rows: print(f'{x["repo"]:28}{x["stars"]:>7}{x["gif"]:>5}{x["video"]:>5}{x["img"]:>5}  {x["first_kind"]} @{x["first_at"]}')
