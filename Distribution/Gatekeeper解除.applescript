use scripting additions

property expectedBundleIdentifier : "jp.pdfbinder.app"

on run
    set targetPath to my findInstalledApp()
    if targetPath is missing value then set targetPath to my requestAppSelection()
    if targetPath is missing value then return

    set dialogResult to display dialog ¬
        "次のPDFBinderの隔離属性を解除し、起動します。\n\n" & targetPath & "\n\nMac全体のGatekeeper設定は変更しません。" ¬
        with title "PDFBinder 初回起動準備" ¬
        buttons {"キャンセル", "解除して起動"} ¬
        default button "解除して起動" ¬
        cancel button "キャンセル" ¬
        with icon caution

    if button returned of dialogResult is not "解除して起動" then return

    try
        do shell script ¬
            "/usr/bin/xattr -dr com.apple.quarantine " & quoted form of targetPath ¬
            with administrator privileges
    on error errorMessage number errorNumber
        display alert "隔離属性を解除できませんでした" message ¬
            "エラー " & errorNumber & ": " & errorMessage ¬
            as critical buttons {"OK"} default button "OK"
        return
    end try

    try
        do shell script "/usr/bin/open " & quoted form of targetPath
        display notification "初回起動の準備が完了しました。" with title "PDFBinder"
    on error errorMessage number errorNumber
        display alert "PDFBinderを起動できませんでした" message ¬
            "隔離属性の解除は完了しています。Applicationsフォルダから起動してください。\n\nエラー " & errorNumber & ": " & errorMessage ¬
            buttons {"OK"} default button "OK"
    end try
end run

-- Applicationsフォルダ内のPDFBinderを、既知の名前とBundle IDから探す
on findInstalledApp()
    set homePath to POSIX path of (path to home folder)
    set candidatePaths to {¬
        "/Applications/PDFBinder.app", ¬
        "/Applications/PDF結合.app", ¬
        homePath & "Applications/PDFBinder.app", ¬
        homePath & "Applications/PDF結合.app"}

    repeat with candidatePath in candidatePaths
        set resolvedPath to contents of candidatePath
        if my isPDFBinder(resolvedPath) then return resolvedPath
    end repeat

    set searchRoots to {"/Applications", homePath & "Applications"}
    repeat with searchRoot in searchRoots
        set rootPath to contents of searchRoot
        try
            do shell script "/bin/test -d " & quoted form of rootPath
            set searchResult to do shell script ¬
                "/usr/bin/mdfind -onlyin " & quoted form of rootPath & ¬
                " 'kMDItemCFBundleIdentifier == \"" & expectedBundleIdentifier & "\"c'"

            repeat with resultPath in paragraphs of searchResult
                set resolvedPath to contents of resultPath
                if my isPDFBinder(resolvedPath) then return resolvedPath
            end repeat
        end try
    end repeat

    return missing value
end findInstalledApp

-- ユーザーが選んだアプリがPDFBinderか確認して返す
on requestAppSelection()
    set dialogResult to display dialog ¬
        "Applicationsフォルダ内でPDFBinderを自動検出できませんでした。\n\nコピーしたPDFBinder.appを選択してください。" ¬
        with title "PDFBinder 初回起動準備" ¬
        buttons {"キャンセル", "アプリを選択…"} ¬
        default button "アプリを選択…" ¬
        cancel button "キャンセル" ¬
        with icon caution

    if button returned of dialogResult is not "アプリを選択…" then return missing value

    try
        set selectedApp to (choose file ¬
            with prompt "コピーしたPDFBinder.appを選択してください。" ¬
            of type {"com.apple.application-bundle"} ¬
            default location (path to applications folder))
        set selectedPath to POSIX path of selectedApp

        if my isPDFBinder(selectedPath) then return selectedPath

        display alert "PDFBinderではありません" message ¬
            "選択したアプリのBundle IDが一致しません。PDFBinder.appを選択してください。" ¬
            as critical buttons {"OK"} default button "OK"
    on error errorMessage number errorNumber
        if errorNumber is -128 then return missing value
        display alert "アプリを選択できませんでした" message ¬
            "エラー " & errorNumber & ": " & errorMessage ¬
            as critical buttons {"OK"} default button "OK"
    end try

    return missing value
end requestAppSelection

-- 指定パスがPDFBinderのアプリバンドルかを判定する
on isPDFBinder(appPath)
    try
        do shell script "/bin/test -d " & quoted form of appPath
        set plistPath to appPath & "/Contents/Info.plist"
        set bundleIdentifier to do shell script ¬
            "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' " & quoted form of plistPath
        return bundleIdentifier is expectedBundleIdentifier
    on error
        return false
    end try
end isPDFBinder
