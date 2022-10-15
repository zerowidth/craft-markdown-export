# Craft -> Obsidian export

This pile of scripts was Good Enough™ to get my [Craft](https://www.craft.do) database exported to markdown for import into [Obsidian](https://obsidian.md).

Craft's default markdown export didn't quite do what I wanted and was going to require too much work to fix by hand, so I rewrote it. I got this working to the point that I was able to export a couple years worth of documents with few enough places needing manual correction that I could complete the process by hand.

## Design

My goals were:

- Export and sanitize craft's realm database to markdown compatible with Obsidian
- Remap daily notes into my preferred daily notes output folder. Folder mappings are defined in `Folder` and `Document`.
- Download attachments for local storage
- Mark subpages for manual correction later
- Compare my conversion to craft's conversion with manual diffing to ensure mapping is "good enough" for iterative development and adjustment.

## Instructions

- [ ] Copy your realm file to `./craft.realm`. You can find it in `~/Library/Containers/com.lukilabs.lukiapp/Data/Library/Application\ Support/com.lukilabs.lukiapp/`, it likely looks like `LukiMain_<uuid>.realm`.
- [ ] Perform a manual markdown export of your space. From `All Documents` choose `Export Contents` -> `Markdown`. Move this export folder to `./craft`. This provides a baseline for comparison.
- [ ] Extract the realm data into JSON: `npm install && npx ts-node src/index.ts`. The contents of your craft space should now be present in `craft.json`.
- [ ] Run the conversion: `ruby convert.rb`.
    - Each file converted will show you a diff. You can configure which diff tool and format this uses in `convert.rb`.
    - For each file, you can choose what to do with the diff. This metadata is stored in `converted.yaml`.
        - "y" marks the file as "good" and you won't see it again unless the output changes.
        - "x" marks the file as "bad", you'll see this diff again when you re-run `convert.rb` unless you mark the file differently
        - "m" marks the file for "needs manual review". The assumption here is that it's "good enough" but will need manual cleanup in the final obsidian vault.
        - "n" skips the file, you'll see it again when you re-run `convert.rb`.
- [ ] If you're happy with things as they are, you're done. Otherwise, edit the conversion code and re-run until things look good. The `converted.yaml` file tracks your decisions about whether files look good or not based on a hash of their contents.
    - You may want to clean up the output directory between runs. To remove markdown but preserve attachments: `find out -name '*.md' -delete`
- [ ] Sync your exported/converted files into your obsidian vault: `rsync -avz out/ path/to/your/vault`.

The final results of the conversion process, including warnings for un-processable conversions and diffs for manual review, will be documented in `Craft Export Results.md`. You can work your way through this file to find and resolve any issues encountered during conversion.

## Bugs/incomplete

I didn't work very hard to handle overlapping styles, which is the majority of conversion errors that require manual fixing. This could probably be improved, but this was good enough and I've migrated now.

There's also an issue with incorrect duplicate style spans being applied in some cases that I didn't track down, e.g. bold being applied twice: `bold` -> `**bold**` -> `****bo**ld**`.

Anyway, good luck.
