# タイトル

A child created by open(FH, '|-') cannot read its STDIN if the parent read STDIN to EOF first
（親が STDIN を EOF まで読んだ後 open(FH, '|-') で作った子プロセスは STDIN を読めない）

# 本文

## Description（説明）

自分の STDIN を最後まで読んだプロセスが `open(FH, '|-')` で書き込み
用の子プロセスを fork すると、子プロセスの STDIN は新しいパイプで
あるにも関わらず、何も読み込めません。fork より前に立った EOF の状態
がそのまま効いています。

この状態はディスクリプタではなく**ハンドル**に属しています。
`open(FH, '|-')` は子プロセスで fd 0 にパイプを dup2 しますが、STDIN
の PerlIO オブジェクトは fork を越えて継承されたものであり、EOF フラグ
もそのまま残ります。子プロセスで `STDIN->clearerr` を呼ぶだけで動くよう
になり、これが原因をそのフラグに特定します。レイヤースタックだけを触る
`binmode STDIN` では直りません。

これは退行ではありません。確認している限り 5.12 以来この挙動です。

## Steps to Reproduce（再現手順）

```perl
$_ = do { local $/; <STDIN> };          # 親が EOF まで読む
if (open(CHLD, '|-') == 0) {
    print <STDIN>;                      # 何も読めない
    exit;
}
print CHLD $_;
```

```
$ printf 'hello\nworld\n' | perl that.pl
$                                       # hello/world を期待
```

子プロセスの先頭に `STDIN->clearerr` を足すと、同じスクリプトが 2 行を
出力します。

## 動くもの、動かないもの

5.12.5 から 5.44.0 までの全リリースで測定
（[結果とワークフロー](https://github.com/kaz-utashiro/perl-stdin-eof-bench)）：

| ケース | 子プロセスの動作 | 結果 |
|---|---|---|
| `plain` | 単に STDIN を読む | 失敗 — 本報告 |
| `exec-cat` | `exec "cat"` | 動く。新しいプログラムは新しいハンドルを得る |
| `read-after-fork` | 親が fork **後**に読む | 動く。回避策ではなく構造の変更 |
| `prime-read` | `scalar <STDIN> if eof STDIN` | **以前は動いた。現在は動かない** |
| `clearerr` | `STDIN->clearerr` | 動く — 最小の修正 |
| `binmode` | `binmode STDIN` | 失敗。レイヤーの問題ではない |
| `fdopen-guard` | `open STDIN, '<&', 0 if eof STDIN` | 動く |
| `fdopen-plain` | `open STDIN, '<&', 0` | 動く。ガードは本質ではない |
| `seek` | `seek STDIN, 0, 0` | 失敗。パイプは seek できない |
| `own-pipe` | 自前の `pipe` + `fork` | 動く |

測定した 16 リリースを通じて、`plain` はどこでも失敗し、`clearerr`、
2 つの fdopen 形式、`read-after-fork`、`own-pipe` はどこでも動きます。
`binmode` と `seek` はどこでも失敗します。動くのは 2 列だけです：

| perl | `plain` | `prime-read` | `clearerr` |
|---|---|---|---|
| 5.12.5 – 5.36.3 | FAIL | ok | ok |
| **5.38.0** – 5.44.0 | FAIL | **FAIL** | ok |

ハンドルから読んで状態を解除する方法 — 2014 年に（優雅ではないが）機能
する選択肢として記録したもの — は **5.38.0** で解除しなくなりました。
いまは子プロセスで `eof STDIN` が真のままで、0 行しか読めません。これは
入力を `@_` に読む方法が 5.42 で止まったのとは別の件です（通常の
`my @x` に読む方法も同様に止まっています）。子プロセス側で復帰する手段
のうち 2 つが失われ、残っているのは `clearerr`、fdopen 相当の再オープン、
自前の pipe の 3 つです。

（`exec-cat` も 5.12.5 と 5.16.3 では失敗します。これは説明できておらず、
プローブが子プロセスの出力を回収する方法に起因する可能性があるので、
深読みしない方がよいと思います。）

## Discussion（議論）

`open(FH, '|-')` は子プロセスの STDIN をパイプで置き換えているのですから、
置き換えられる側のハンドルが持つ EOF／エラー状態は新しいディスクリプタ
には無関係であり、子プロセス側でそれを解除するのが自然に見えます
（いま手作業で `STDIN->clearerr` がやっていることです）。少なくとも、
`open` の `'|-'` 形式のドキュメントに注記する価値はあると思います。
「子プロセスの STDIN はパイプになる」という素直な読み方からは、fork
以前の状態がなお効いているとは思えないからです。

これは #24883 と同じ形です。あちらは標準ハンドルの PerlIO オブジェクト
がディスクリプタの差し替えを越えて生き残り、レイヤースタックを持ち越し
ます。こちらは EOF フラグを持ち越します。

## Real-world impact（実世界での影響）

[App::Greple](https://metacpan.org/dist/App-Greple) で発見しました。
出力フィルタを設定すると、素朴な実装では入力ファイルの数だけフィルタ
プロセスが起動されます。マッチしたかどうかに関わらずです。したがって
マッチが判明してから初めてフィルタを起動する必要があり、それは fork
より前に入力を読むことを意味します。13,000 個の小さなファイル
（1 イベント 1 ファイルのカレンダー）があるディレクトリを検索するのは、
そうして初めて実用的になります。2014 年以来、回避策は fdopen 相当の
再オープンです。

「先に読んで、後で fork する」フィルタを書く人は誰でもこれに当たります。
しかも症状は「子プロセスが黙って何も出さない」なので、原因の手がかりが
まったくありません。

2014 年の記事（日本語）は今も残っています：
https://qiita.com/kaz-utashiro/items/80fc83e56e645f19e927

## Perl configuration（環境）

ubuntu-latest + shogo82148/actions-setup-perl のビルド
（5.12.5〜5.44.0）で測定。macOS/arm64 + Homebrew perl 5.44.0 でも再現。

perl -V の全文は英語版 (ISSUE-DRAFT.md) の `<details>` ブロックに
あります。
