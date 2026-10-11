This is an Elixir library that does Kinyarwanda content moderation, profanity
filtering and hate speech detection for Elixir and Phoenix.

## Project guidelines

- **Scratch files go in `tmp/`, never in the repo root.** `tmp/` is gitignored
  for exactly this reason. Any probe script, throwaway lexicon, or one-off
  experiment belongs in `tmp/`, so a crashed run can never leave files that
  show up in `git status` or get accidentally committed.
- **Do not test against the OS temp directory.** Write scratch files into the
  repo-local `tmp/` via `KinyarwandaModeration.Tmp`, not `System.tmp_dir!()`.
  `System.tmp_dir!()` scatters files outside the project where they pile up
  invisibly; `tmp/` keeps them in one place that is ignored and easy to clear.
- **Tests own their temp files.** Every file a test writes must be removed by an
  `on_exit/1` callback, so `tmp/` is empty again when the suite finishes. Use
  `Tmp.path/1` or `Tmp.write!/2` for the name: they prefix a per-process marker
  so asynchronous test files can never collide on the same file.
- **Use `mix precommit` when you are done and fix every pending issue.** It runs
  `format --check-formatted`, `compile --warnings-as-errors` and `test`. A
  change is not finished until it is green.
- **Keep the public API documented.** Anything user-facing needs a `@doc` with
  a doctest where the behaviour is expressible as one. The doctests are part of
  the suite and a broken example fails `mix precommit`.
- **Never change the lexicon data under `data/` to make a test pass.**
  Matching behaviour is the thing under test, not the data.

## Normalizer rule order

`Normalizer.normalize/2` applies its rules in a fixed order, and that order is
load-bearing:

    strip_accents  ->  downcase  ->  collapse_repeats  ->  squash_doubles  ->  fold_l_r  ->  apostrophes  ->  whitespace

`collapse_repeats` must stay ahead of `squash_doubles`. A three-letter run such
as `amaaani` already satisfies the squash on its own, so running the squash
first would collapse it even with `collapse_repeats: false` and make that switch
unobservable. Both rules read the same input, so a reorder is a silent behaviour
change rather than a compile error.

Doubled letters are squashed without an exception list. `nny` looks like a
special case, but it is just `n` followed by the `ny` digraph, so shrinking it is
the same edit that collapses doubled-`n` padding and the two cannot be told
apart. They do not need to be: the lexicon side is squashed identically, so a
term listed as `innyo` is matched by `innyo`, `inyo` and `innyoo` alike. There is
a regression test pinning this, and one pinning that padding `ny` as `nny` does
not evade a listed `kanywenzobya`.

## Regression tests

Kinyarwanda derivation rules interact, so a fix in one rule routinely reopens a
case another rule used to reject. Every bug fix must land with a test that fails
before it and passes after it.

- **Put regression cases in a `describe "regressions"` block** at the end of the
  file that owns the behaviour, tagged as a group, or tag an individual test with
  `@tag :regression` when it belongs alongside the feature it protects:

      describe "regressions" do
        @describetag :regression

        setup do
          %{m: built(lexicon_with(["cumita"]))}
        end

        test "the augment rule never stacks", %{m: m} do
          assert actions(m, "ndigigituba") == {:allow, []}
        end
      end

  Either form makes the set selectable: `mix test --only regression`.
- **Name the symptom, not the fix.** `"does not flag 'nywe nzobya' as the glued
  phrase"` says what must stay true; `"fix augment stacking"` does not.
- **Assert the surrounding cases too.** A test that only pins the fixed sentence
  will not notice the fix widening to sentences that should stay clean. Include
  at least one near-miss that must still be `:allow`.
- **Known limitations get a test as well.** A case the matcher knowingly does not
  handle is pinned with the behaviour it has today and a comment saying so, so
  that closing the gap is a deliberate act rather than an accident.
- **Prefer `check/2` with an explicit `matcher:` or `lexicon:`.** Tests that
  depend on the process-wide installed matcher leak across files through
  `:persistent_term` and become seed-order dependent.

## Normalizer pipeline

`Normalizer.normalize/2` applies its steps in a fixed order, and that order is
load-bearing:

    strip_accents -> downcase -> fold_l_r -> collapse_repeats -> squash_doubles
      -> apostrophes -> whitespace -> trim

- **`fold_l_r` must stay ahead of the two squashes.** It is the only step that
  rewrites one letter into another (every *l* becomes *r*), so running it last
  lets it leave a doubled letter behind that nothing collapses: `lrl` becomes
  `rrr`, then `r`. That is invisible for a single token, because the matcher
  normalizes input tokens a second time through `Normalizer.variants/2`, but it
  makes `normalize/2` non-idempotent and makes `variants/2` disagree with
  `normalize/2` about the same token. Folding first means every letter is
  already in its final form before the squashes run, so a second pass changes
  nothing. Folding is one way (*l* to *r*), which is enough: the lexicon side
  folds too, so `gaswere` and `gaswele` reach the same token and a term can be
  listed in either spelling.
- **`collapse_repeats` must stay before `squash_doubles`.** Squashing collapses
  any letter run to one, so if it ran first a single run of three (`amaaani`)
  would reach `amani` and `collapse_repeats: false` would stop being observable.
  Keeping the order means `collapse_repeats` still owns runs of three or more and
  `squash_doubles` only has to handle the doubled-letter padding below that
  threshold (`igiituba`, `igituuba`, `igitubba`).
- **`strip_accents` runs before downcase**, not after.
- **Every rule is a switch** in `@defaults`, surfaced per-lexicon through the
  `"normalization"` object. Adding or renaming one means updating three places
  that do not share a source: `@defaults` in `normalizer.ex`, the `normalization`
  properties under `definitions/structured` in `data/lexicon.schema.json`
  (which sets `"additionalProperties": false`), and the rule table in
  `README.md`. `@option_names` derives itself from `@defaults`, so it needs no
  separate edit.
- **Squashing is symmetric.** It runs on the lexicon and on the input identically,
  so a listed long-vowel spelling and its squashed form match either way. Precision
  is only at risk if squashing merges two *distinct listed* entries; check that
  against `data/rw_hate_speech.json` before changing the rule.

## Layout

- `lib/kinyarwanda_moderation.ex` - the public API: `check/2`, `reload/2`, `compile/2`
- `lib/kinyarwanda_moderation/normalizer.ex` - text normalisation and variant expansion
- `lib/kinyarwanda_moderation/lexicon.ex` - loads and builds lexicons, expands entries
- `lib/kinyarwanda_moderation/matcher.ex` - the compiled multi-pattern matcher
- `lib/kinyarwanda_moderation/result.ex` - the `Result` struct and its helpers
- `data/` - bundled lexicon JSON
- `test/support/` - test-only helpers, compiled only in `:test`

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- usage-rules-end -->
