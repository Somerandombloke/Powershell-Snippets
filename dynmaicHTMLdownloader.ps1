			$ie = New-Object -ComObject InternetExplorer.Application
			$ie.Visible = $false
			$url = "https://airsdk.harman.com/runtime"
			$ie.Navigate($url)
			while ($ie.Busy -eq $true -or $ie.ReadyState -ne 4) {
				Start-Sleep -Seconds 1
			}
			$dynamicHtml = $ie.document.body.outerHTML
			$Version = [regex]::Match($dynamicHtml,"assets/downloads/(.*?)/AdobeAIR.exe").Groups[1].Value
			$URL = "https://airsdk.harman.com/assets/downloads/$Version/AdobeAIR.exe"
			$ie.Quit()
