# Sich promo video

A [Remotion](https://www.remotion.dev) edit of real app footage: the title, the
3D window entrance, camera push-ins, cursor, captions and outro are all code;
every pixel of the app itself is a recording of the shipped UI on synthetic data.

## Regenerate

```sh
# 1. Record footage of the real app (writes public/footage.mp4 + public/beats.json)
caffeinate -d -u -i sh app/scripts/promo-footage.sh

# 2. Preview or tweak the edit (camera shots and captions live in src/timeline.ts)
cd promo && npm i && npx remotion studio

# 3. Render everything into ../assets/
./render.sh
```

That writes the short hero GIF (`hero.gif`, the README's opener), one GIF per
feature section (`feature-*.gif`), the full one-minute tour (`promo.mp4`) and
the social preview. The hero and feature GIFs are cuts of the same footage,
listed in `CLIPS` in `src/timeline.ts`.

Camera shots, captions and the cursor are keyed to the beat names in
`public/beats.json`, so a re-recorded take with different timing re-syncs on its own.

Remotion is free for individuals and companies of up to 3 people; larger
companies need a [company license](https://www.remotion.pro/license).
