# Hero Reader art style: "Cosmic Storybook"

A bright, friendly, flat-vector look that reads well at small sizes, scales
cleanly on any screen (SVG imports straight into Godot), and is easy to extend
to new scenarios (space invaders, missile defense, undersea, dinosaurs...).

## Rules

- **Shapes:** chunky and rounded, with no sharp spikes except stars and sparkles.
  Faces are slightly wider than real life, with big friendly eyes.
- **Outlines:** 6 px `#141836` (deep navy) on a 512 px canvas, round joins and caps.
  Interior detail lines (hair strands, beard texture) are 3–4 px in a darker tone of the fill.
- **Shading:** flat fills with at most one darker tone per material, plus one soft
  highlight stroke on hair. No gradients, except the portrait-badge background.
- **Expressions:** always positive. Determined, excited, proud, or "oops, try again".
  Never angry or sad. This is part of the minimize-negative-feedback goal.
- **Portrait badges:** 512×512 circle with a radial gradient background, small cream
  dots for stars, and one gold 4-point sparkle.

## Palette

| Role | Hex |
|---|---|
| Space navy (bg, outlines) | `#1B1F4B` / `#141836` |
| Commander blue (uniform) | `#2B3A8C` |
| Hero plum (Nora's suit) | `#9B5D8C`, stripes `#C99BBE` |
| Laser teal (headsets, UI accents, zaps) | `#2EC4B6` |
| Star gold (rank, badges, rewards) | `#FFC93C` |
| Corgi orange (accent, sidekick?) | `#FF7A45` |
| Cream (text, highlights) | `#FFF4DC` |

## Characters

- **Commander Aaron** (`characters/commander_aaron.svg`): mission giver. Short
  tousled light-brown hair flicked up to one side, heavy brows, blue eyes,
  full reddish-brown beard greying at the chin. Navy uniform with gold
  shoulder boards and a star badge, plus a comms headset. Expression: warm,
  confident "ready, hero?" smile.
- **Hero Nora** (`characters/hero_nora.svg`): the reader. Long wavy blonde
  hair with side-swept bangs. Plum flight suit with pale stripes (a nod to
  her favourite striped shirt), a teal collar, and an open-book star badge.
  She wears the same headset as the Commander. Expression: big determined grin.

The reference photos are kept out of the repo (see `.gitignore`: `art/reference/`).

## Next variants to draw

Each character needs these expressions: happy, excited (word zapped), "hmm" (a miss
followed by try again), cheering (level complete), and talking (mouth open, for mission
briefings).
