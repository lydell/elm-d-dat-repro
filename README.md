# elm-d-dat-race

Sometimes `elm make` fails like this when there is no `elm-stuff/` folder:

```
-- ERROR -----------------------------------------------------------------------

I ran into something that bypassed the normal error reporting process! I
extracted whatever information I could from the internal error:

>   /home/runner/work/user/repo/elm-stuff/0.19.3/d.dat: withBinaryFile: resource busy (file is locked)
```

At work, this happens in CI (GitHub Actions, Ubuntu, no `elm-stuff/`) almost every day since we upgraded to 0.19.3. Before that, we saw it every few weeks or so. Retrying always helps. I’ve never seen it locally (`elm-stuff/` basically always exists there).

## Reproduce

There are two projects, which share `src/` and `Outside.elm`:

- `small/elm.json`: Just `elm/core` and `elm/json`
- `big/elm.json`: 55 packages

And three files to compile:

- `Outside.elm`: Outside `source-directories`.
- `src/TypeError.elm`: Inside `source-directories`, with a type error.
- `src/Ok.elm`: Inside `source-directories`, compiles fine.

`repro.sh` runs `rm -rf elm-stuff && elm make --output=/dev/null <file>` in a loop, and counts how many times it fails with “file is locked”.

```sh
cd small # or big
../repro.sh ../Outside.elm 100
GHCRTS=-N1 ../repro.sh ../Outside.elm 100
GHCRTS=-N2 ../repro.sh ../src/TypeError.elm 100
```

Limiting the number of cores with `GHCRTS=-N1` or `GHCRTS=-N2` usually makes it happen more often. I think that’s why CI runners hit it so much more than my laptop. [GitHub Actions docs about CPU cores](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for--private-repositories).

## Results

I ran this with:

- 100 runs (per row in the table)
- Elm 0.19.3
- MacBook with 14 cores

How many times “file is locked” happened:

| Project | File                | `-N1` | `-N2` |
| ------- | ------------------- | ----- | ----- |
| small   | `Outside.elm`       | 6     | 8     |
| small   | `src/TypeError.elm` | 1     | 1     |
| small   | `src/Ok.elm`        | 0     | 0     |
| big     | `Outside.elm`       | 33    | 1     |
| big     | `src/TypeError.elm` | 9     | 1     |
| big     | `src/Ok.elm`        | 0     | 0     |

(The numbers vary quite a bit between runs.)

With the small project, 0.19.1 and 0.19.2 got 0/100 for `Outside.elm` with both `-N1` and `-N2`. With the big project and all cores, all three versions fail a few times per 150 runs.

## What I think is going on

There seems to be two functions for writing bytes to files:

https://github.com/elm/compiler/blob/0.19.3/builder/src/File.hs#L212-L223

```hs
writeBytes :: Writer t -> FilePath -> (a -> B.Builder) -> a -> IO ()
writeBytes writer path func value =
  writeBuilder writer path (func value)


writeBytes_ :: Writer t -> FilePath -> (a -> B.Builder) -> a -> IO ()
writeBytes_ writer@(Writer workList) path func value =
  do  mvar <- newEmptyMVar
      _ <- forkIO (writeBuilder writer path (func value) >> putMVar mvar ())
      oldWork <- takeMVar workList
      let !newWork = mvar:oldWork
      putMVar workList newWork
```

If I understand it correctly, `writeBytes` writes synchronously, while `writeBytes_` writes in the background on another thread.

It looks like `withWriter` can be used to wait for a background write to finish:

https://github.com/elm/compiler/blob/0.19.3/builder/src/File.hs#L80-L97

```hs
-- FILE WRITER
--
-- This allows for background writes that are guaranteed to complete even if
-- they take a bit longer than the actual program itself. Background writes are
-- indicated with a trailing underscore.


newtype Writer t =
  Writer (MVar [MVar ()])


withWriter :: (Writer t -> IO a) -> IO a
withWriter callback =
  do  workList <- newMVar []
      result <- callback (Writer workList)
      mvars <- takeMVar workList
      traverse_ takeMVar mvars
      return result
```

When `d.dat` is missing (or `elm.json` has changed), `verifyDependencies` writes to `d.dat` using `File.writeBytes_` (the async one):

https://github.com/elm/compiler/blob/0.19.3/builder/src/Elm/Details.hs#L336-L338

```hs
          do  File.writeBytes_ writer (R.objects    stuff) Opt.eGlobalGraph objs
              File.writeBytes_ writer (R.interfaces stuff) (E.dict32 ModuleName.eCanonical I.eDependencyInterface) ifaces
              File.writeBytes_ writer (R.details    stuff) eDetails details
```

After the dependencies are dealt with, `writeDetails` (via [Build.fromPaths](https://github.com/elm/compiler/blob/0.19.3/builder/src/Build.hs#L196-L200)) writes to `d.dat` using `File.writeBytes` (the sync one):

https://github.com/elm/compiler/blob/0.19.3/builder/src/Build.hs#L734-L737

```hs
writeDetails :: File.Writer R.PROJECT -> R.Stuff -> Details.Details -> Map.Map Module.Name Result -> IO ()
writeDetails writer stuff (Details.Details time outline buildID locals foreigns extras) results =
  File.writeBytes writer (R.details stuff) Details.eDetails $
    Details.Details time outline buildID (Map.foldrWithKey addNewLocal locals results) foreigns extras
```

The only relevant `withWriter` I could find wraps all of `elm make` ([runHelp](https://github.com/elm/compiler/blob/0.19.3/terminal/src/Make.hs#L75-L88), via [Root.withRootLock](https://github.com/elm/compiler/blob/0.19.3/builder/src/Root.hs#L173-L177)), so all background writes are waited for at the very end. But nothing waits for the background write of `d.dat` from `Details.load` (which eventually calls `verifyDependencies`) before `writeDetails` writes `d.dat` again. So it looks like there is a risk that the build step tries to open `d.dat` for writing while the dependencies step still has it [open](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/System-IO.html#g:9).

`Outside.elm` hits this the most because files outside `source-directories` seem to be compiled in `checkRoot`, concurrently (?) with `writeDetails`, so there’s almost no work between the two writes.
