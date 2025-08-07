#Requires -Version 5.1
Add-Type -AssemblyName PresentationFramework

# --- Global Variables ---
$script:Environment = 'TEST'  # Default environment
$script:hostname = ""
$script:port = ""
$script:username = ""
$script:password = ""
$vhost = "/"
$configFilePath = "$env:USERPROFILE\RabbitMQConfig.json"
$groupFilePath = "$env:USERPROFILE\RabbitMQGroups.json"
$logFilePath = "$env:USERPROFILE\RabbitMQLog.txt"
$script:GroupedQueues = @{}
$script:cachedQueues = $null
$script:displayLimit = 250
$script:searchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:sortColumn = "MessageCount"
$script:sortDirection = "Descending"

# --- Function Definitions ---

function userEntrance {
    [xml]$xaml = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="RabbitMQ Bağlantı Ayarları" Height="280" Width="400" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="#E6ECEF">
        <Window.Resources>
            <Style TargetType="Button"><Setter Property="Padding" Value="10"/><Setter Property="Margin" Value="5"/><Setter Property="FontSize" Value="13"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="5"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#4A90E2"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#357ABD"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
            </Style>
            <Style TargetType="TextBox"><Setter Property="Padding" Value="5"/><Setter Property="FontSize" Value="14"/><Setter Property="Margin" Value="5"/><Setter Property="BorderThickness" Value="1"/><Setter Property="BorderBrush" Value="#B0BEC5"/></Style>
            <Style TargetType="PasswordBox"><Setter Property="Padding" Value="5"/><Setter Property="FontSize" Value="14"/><Setter Property="Margin" Value="5"/><Setter Property="BorderThickness" Value="1"/><Setter Property="BorderBrush" Value="#B0BEC5"/></Style>
            <Style TargetType="Label"><Setter Property="FontSize" Value="14"/><Setter Property="Margin" Value="5"/><Setter Property="Foreground" Value="#2C3E50"/></Style>
            <Style TargetType="CheckBox"><Setter Property="FontSize" Value="14"/><Setter Property="Margin" Value="5"/><Setter Property="Foreground" Value="#2C3E50"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
            <Style TargetType="ComboBox"><Setter Property="Padding" Value="5"/><Setter Property="FontSize" Value="14"/><Setter Property="Margin" Value="5"/><Setter Property="BorderThickness" Value="1"/><Setter Property="BorderBrush" Value="#B0BEC5"/></Style>
        </Window.Resources>
        <Grid Margin="10">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Label Grid.Row="0" Grid.Column="0" Content="Hostname:"/>
            <TextBox Name="HostnameBox" Grid.Row="0" Grid.Column="1" Text=""/>
            <Label Grid.Row="1" Grid.Column="0" Content="Port:"/>
            <TextBox Name="PortBox" Grid.Row="1" Grid.Column="1" Text=""/>
            <Label Grid.Row="2" Grid.Column="0" Content="Username:"/>
            <TextBox Name="UsernameBox" Grid.Row="2" Grid.Column="1" Text=""/>
            <Label Grid.Row="3" Grid.Column="0" Content="Password:"/>
            <PasswordBox Name="PasswordBox" Grid.Row="3" Grid.Column="1" Password=""/>
            <Label Grid.Row="4" Grid.Column="0" Content="Environment:"/>
            <ComboBox Name="EnvironmentBox" Grid.Row="4" Grid.Column="1" SelectedIndex="0">
                <ComboBoxItem Content="TEST"/>
                <ComboBoxItem Content="PROD"/>
            </ComboBox>
            <CheckBox Name="SaveCredentialsCheckBox" Grid.Row="5" Grid.Column="1" Content="Bağlantı ayarlarını kaydet"/>
            <Button Name="ConnectButton" Grid.Row="5" Grid.Column="1" Content="Bağlan" Background="#2ECC71" HorizontalAlignment="Right"/>
        </Grid>
    </Window>
"@
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $HostnameBox = $window.FindName("HostnameBox")
    $PortBox = $window.FindName("PortBox")
    $UsernameBox = $window.FindName("UsernameBox")
    $PasswordBox = $window.FindName("PasswordBox")
    $EnvironmentBox = $window.FindName("EnvironmentBox")
    $SaveCredentialsCheckBox = $window.FindName("SaveCredentialsCheckBox")
    $ConnectButton = $window.FindName("ConnectButton")

    if (Test-Path $configFilePath) {
        try {
            $config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
            $HostnameBox.Text = $config.hostname
            $PortBox.Text = $config.port
            $UsernameBox.Text = $config.username
            $PasswordBox.Password = $config.password
            if ($config.environment -in @("TEST", "PROD")) {
                $EnvironmentBox.SelectedItem = $EnvironmentBox.Items | Where-Object { $_.Content -eq $config.environment }
            }
        } catch { }
    }

    $ConnectButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($HostnameBox.Text) -or [string]::IsNullOrWhiteSpace($PortBox.Text) -or [string]::IsNullOrWhiteSpace($UsernameBox.Text) -or [string]::IsNullOrWhiteSpace($PasswordBox.Password) -or $null -eq $EnvironmentBox.SelectedItem) {
            [System.Windows.MessageBox]::Show("Lütfen tüm alanları doldurun.", "Uyarı", "OK", "Warning")
            return
        }
        if (-not ($PortBox.Text -match '^\d+$')) {
            [System.Windows.MessageBox]::Show("Port numarası sadece rakamlardan oluşmalıdır.", "Uyarı", "OK", "Warning")
            return
        }
        $script:hostname = $HostnameBox.Text
        $script:port = $PortBox.Text
        $script:username = $UsernameBox.Text
        $script:password = $PasswordBox.Password
        $script:Environment = $EnvironmentBox.SelectedItem.Content
        $script:protocol = if ($script:Environment -eq 'PROD') { 'https' } else { 'http' }
        
        if ($script:Environment -eq 'PROD') {
            Add-Type @"
            using System.Net;
            using System.Security.Cryptography.X509Certificates;
            public class TrustAllCertsPolicy : ICertificatePolicy {
                public bool CheckValidationResult(
                    ServicePoint srvPoint, X509Certificate certificate,
                    WebRequest request, int certificateProblem) {
                    return true;
                }
            }
"@
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        }

        if ($SaveCredentialsCheckBox.IsChecked) {
            try {
                @{ hostname = $script:hostname; port = $script:port; username = $script:username; password = $script:password; environment = $script:Environment } | ConvertTo-Json | Set-Content -Path $configFilePath -ErrorAction Stop
            } catch { }
        }
        $window.Close()
    })
    $window.ShowDialog() | Out-Null
    if ([string]::IsNullOrWhiteSpace($script:hostname)) { exit }
}

function Set-AuthHeader {
    $pair = "${script:username}:${script:password}"
    $script:encodedAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    $script:headers = @{ Authorization = "Basic $script:encodedAuth"; "Content-Type" = "application/json" }
}

function UrlEncode($string) {
    return [System.Net.WebUtility]::UrlEncode($string)
}

function Get-Queues {
    $uri = "${script:protocol}://${script:hostname}:${script:port}/api/queues/$(UrlEncode $vhost)"
    try {
        return Invoke-RestMethod -Uri $uri -Headers $script:headers -Method Get -ErrorAction Stop -TimeoutSec 180
    } catch {
        [System.Windows.MessageBox]::Show("API bağlantı hatası: $($_.Exception.Message)", "Hata", "OK", "Error")
        return $null
    }
}

function Update-ListView($queuesToShow) {
    $QueueListView.ItemsSource = $queuesToShow
}

function Search-And-Display-Queues {
    if ($null -eq $script:cachedQueues) {
        $QueueListView.ItemsSource = $null
        $script:cachedQueues = Get-Queues
        if ($null -eq $script:cachedQueues) {
            [System.Windows.MessageBox]::Show("API'den veri çekilemedi. Bağlantıyı kontrol edin.", "Hata", "OK", "Error")
            return
        }
        $LastRefreshLabel.Text = "Son Yenileme: $(Get-Date -Format 'HH:mm:ss')"
    }
    
    $allQueues = $script:cachedQueues
    $filter = $SearchBox.Text.Trim()
    $useRegex = $RegexSearchCheckBox.IsChecked
    
    $matched = if ([string]::IsNullOrEmpty($filter) -or $filter -eq "Kuyrukları ara...") {
        $allQueues
    } elseif ($useRegex) {
        try { $allQueues | Where-Object { $_.name -match "$([System.Text.RegularExpressions.Regex]::Escape($filter))$" } } catch { return }
    } else {
        $allQueues | Where-Object { $_.name -and $_.name.ToLower().Contains($filter.ToLower()) }
    }

    $displayObjects = $matched | ForEach-Object {
        [PSCustomObject]@{
            Name         = $_.name
            MessageCount = ($_.messages_ready + $_.messages_unacknowledged)
            Ready        = $_.messages_ready
            Unacked      = $_.messages_unacknowledged
        }
    }

    $isDescending = $script:sortDirection -eq "Descending"
    $sortedObjects = $displayObjects | Sort-Object -Property $script:sortColumn -Descending:$isDescending
    
    $limitedObjects = @($sortedObjects | Select-Object -First $script:displayLimit)
    
    Update-ListView -queuesToShow $limitedObjects
    $QueueCountLabel.Text = "Kuyruk Adedi: $($script:cachedQueues.Count)"
    Update-SortIndicators
}

function Update-SortIndicators {
    $Header_Name.Content = "Kuyruk Adı"
    $Header_MessageCount.Content = "Mesaj Sayısı"
    $arrow = if ($script:sortDirection -eq "Ascending") { " ▲" } else { " ▼" }
    if ($script:sortColumn -eq "Name") { $Header_Name.Content += $arrow } 
    elseif ($script:sortColumn -eq "MessageCount") { $Header_MessageCount.Content += $arrow }
}

function Save-Groups {
    try {
        $GroupedQueues | ConvertTo-Json | Set-Content -Path $groupFilePath -ErrorAction Stop
        [System.Windows.MessageBox]::Show("Gruplar başarıyla kaydedildi.", "Bilgi", "OK", "Information")
    } catch {
        $errorMsg = "Gruplar kaydedilemedi: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($errorMsg, "Hata", "OK", "Error")
        Add-Content -Path $logFilePath -Value "[$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss zzz')] $errorMsg"
    }
}

function Load-Groups {
    if (-not (Test-Path $groupFilePath)) {
        $script:GroupedQueues = @{}
        [System.Windows.MessageBox]::Show("Grup dosyası ($groupFilePath) bulunamadı. Yeni bir grup listesi oluşturulacak.", "Bilgi", "OK", "Information")
        return
    }

    try {
        $jsonContent = Get-Content -Path $groupFilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($jsonContent)) {
            $script:GroupedQueues = @{}
            [System.Windows.MessageBox]::Show("Grup dosyası boş. Yeni bir grup listesi oluşturulacak.", "Bilgi", "OK", "Information")
            return
        }
        $jsonObject = $jsonContent | ConvertFrom-Json -ErrorAction Stop
        $script:GroupedQueues = @{}
        foreach ($prop in $jsonObject.PSObject.Properties) {
            $script:GroupedQueues[$prop.Name] = $prop.Value
        }
        Refresh-GroupedTreeView
    } catch {
        $errorMsg = "Gruplar yüklenemedi: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($errorMsg, "Hata", "OK", "Error")
        Add-Content -Path $logFilePath -Value "[$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss zzz')] $errorMsg"
        $script:GroupedQueues = @{}
        Refresh-GroupedTreeView
    }
}

function Refresh-QueueDisplayListBox {
    $QueueDisplayListBox.Items.Clear()
    $selectedItems = $QueueListView.SelectedItems
    if ($selectedItems.Count -eq 0) {
        $QueueDisplayListBox.Items.Add("Detay için kuyruk seçin.")
        return
    }
    foreach ($item in $selectedItems) {
        $QueueDisplayListBox.Items.Add($item.Name)
        $QueueDisplayListBox.Items.Add("  Toplam: $($item.MessageCount)")
        $QueueDisplayListBox.Items.Add("  Hazır (Ready): $($item.Ready)")
        $QueueDisplayListBox.Items.Add("  Bekleyen (Unacked): $($item.Unacked)")
        $QueueDisplayListBox.Items.Add("--------------------")
    }
}

function Refresh-GroupedTreeView {
    $GroupedTreeView.Items.Clear()
    foreach ($group in $GroupedQueues.Keys | Sort-Object) {
        $groupItem = New-Object System.Windows.Controls.TreeViewItem
        $groupItem.Header = "📁 $group"
        $groupItem.Tag = "Group:$group"
        foreach ($queue in $GroupedQueues[$group] | Sort-Object) {
            $queueItem = New-Object System.Windows.Controls.TreeViewItem
            $queueItem.Header = $queue
            $queueItem.Tag = "Queue:$queue"
            $groupItem.Items.Add($queueItem)
        }
        $GroupedTreeView.Items.Add($groupItem)
    }
}

function Group-SelectedQueues {
    $selectedQueues = $QueueListView.SelectedItems
    if ($selectedQueues.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Lütfen en az bir kuyruk seçin.", "Uyarı", "OK", "Warning")
        return
    }

    $groupName = $GroupBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($groupName) -or $groupName -eq "Grup ismi yaz...") { 
        [System.Windows.MessageBox]::Show("Lütfen grup (klasör) adı girin.", "Uyarı", "OK", "Warning")
        return
    }

    if (-not $GroupedQueues.ContainsKey($groupName)) {
        $GroupedQueues[$groupName] = @()
    }

    foreach ($item in $selectedQueues) {
        $queueName = $item.Name
        if (-not $GroupedQueues[$groupName].Contains($queueName)) {
            $GroupedQueues[$groupName] += $queueName
        }
    }

    Refresh-GroupedTreeView
    Save-Groups
}

function Delete-SelectedGroup {
    $selected = $GroupedTreeView.SelectedItem
    if ($null -eq $selected) {
        [System.Windows.MessageBox]::Show("Silinecek grup seçilmedi.", "Uyarı", "OK", "Warning")
        return
    }

    if ($selected.Tag -match "^Group:(.+)$") {
        $group = $matches[1]
        $confirm = [System.Windows.MessageBox]::Show("Grup '$group' silinsin mi?", "Onay", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            $GroupedQueues.Remove($group)
            Refresh-GroupedTreeView
            Save-Groups
        }
    } else {
        [System.Windows.MessageBox]::Show("Lütfen silmek için grup başlığı seçin.", "Uyarı", "OK", "Warning")
    }
}

function Add-QueueToSelectedGroup {
    $selectedGroup = $GroupedTreeView.SelectedItem
    if ($null -eq $selectedGroup -or -not ($selectedGroup.Tag -match "^Group:(.+)$")) {
        [System.Windows.MessageBox]::Show("Lütfen önce grubu seçin.", "Uyarı", "OK", "Warning")
        return
    }
    $groupName = $matches[1]

    $selectedQueues = $QueueListView.SelectedItems
    if ($selectedQueues.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Lütfen kuyruk(lar) seçin.", "Uyarı", "OK", "Warning")
        return
    }

    foreach ($item in $selectedQueues) {
        $queueName = $item.Name
        if (-not $GroupedQueues[$groupName].Contains($queueName)) {
            $GroupedQueues[$groupName] += $queueName
        }
    }
    Refresh-GroupedTreeView
    Save-Groups
}

function Remove-QueueFromSelectedGroup {
    $selected = $GroupedTreeView.SelectedItem
    if ($null -eq $selected) {
        [System.Windows.MessageBox]::Show("Lütfen silmek istediğiniz kuyruğu seçin.", "Uyarı", "OK", "Warning")
        return
    }
    if ($selected.Tag -match "^Queue:(.+)$") {
        $queueName = $matches[1]
        foreach ($group in $GroupedQueues.Keys) {
            if ($GroupedQueues[$group].Contains($queueName)) {
                $GroupedQueues[$group] = $GroupedQueues[$group] | Where-Object { $_ -ne $queueName }
                if ($GroupedQueues[$group].Count -eq 0) {
                    $GroupedQueues.Remove($group)
                }
                Refresh-GroupedTreeView
                Save-Groups
                return
            }
        }
    } else {
        [System.Windows.MessageBox]::Show("Lütfen silmek istediğiniz kuyruk öğesini seçin.", "Uyarı", "OK", "Warning")
    }
}

function Delete-SelectedQueues {
    $selectedItems = $QueueListView.SelectedItems
    if ($selectedItems.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Lütfen en az bir kuyruk seçin.", "Uyarı", "OK", "Warning")
        return
    }

    $confirm = [System.Windows.MessageBox]::Show("Seçilen $($selectedItems.Count) kuyruk silinsin mi?", "Onay", "YesNo", "Question")
    if ($confirm -ne "Yes") { return }

    $encodedVhost = UrlEncode $vhost
    $successCount = 0
    $failCount = 0

    foreach ($item in $selectedItems) {
        $queueName = $item.Name
        $encodedQueue = UrlEncode $queueName
        $uri = "${script:protocol}://${script:hostname}:${script:port}/api/queues/$encodedVhost/$encodedQueue"
        try {
            Invoke-RestMethod -Uri $uri -Headers $script:headers -Method Delete -ErrorAction Stop
            $successCount++
            Add-Content -Path $logFilePath -Value "[$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss zzz')] Kuyruk silindi: $queueName"
        } catch {
            $errorMsg = "Silinemedi: $queueName - $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($errorMsg, "Hata", "OK", "Error")
            Add-Content -Path $logFilePath -Value "[$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss zzz')] $errorMsg"
            $failCount++
        }
    }

    $script:cachedQueues = $null
    Search-And-Display-Queues
    if ($failCount -gt 0) {
        [System.Windows.MessageBox]::Show("Silme tamamlandı. $successCount kuyruk silindi, $failCount kuyrukta hata oluştu.", "Bilgi", "OK", "Information")
    } else {
        [System.Windows.MessageBox]::Show("Silme tamamlandı. $successCount kuyruk başarıyla silindi.", "Bilgi", "OK", "Information")
    }
}

function Purge-SelectedQueuesMessages {
    $selectedItems = $QueueListView.SelectedItems
    if ($selectedItems.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Lütfen en az bir kuyruk seçin.", "Uyarı", "OK", "Warning")
        return
    }

    $confirm = [System.Windows.MessageBox]::Show("Seçilen $($selectedItems.Count) kuyruğun mesajları temizlensin mi?", "Onay", "YesNo", "Question")
    if ($confirm -ne "Yes") { return }

    $encodedVhost = UrlEncode $vhost
    $successCount = 0
    $failCount = 0
    $zeroMessageCount = 0

    $queues = Get-Queues

    foreach ($item in $selectedItems) {
        $queueName = $item.Name
        $queueInfo = $queues | Where-Object { $_.name -eq $queueName }
        $totalMessages = $queueInfo.messages_ready + $queueInfo.messages_unacknowledged
        if ($totalMessages -eq 0) {
            $zeroMessageCount++
            continue
        }

        $encodedQueue = UrlEncode $queueName
        $uri = "${script:protocol}://${script:hostname}:${script:port}/api/queues/$encodedVhost/$encodedQueue/contents"
        try {
            Invoke-RestMethod -Uri $uri -Headers $script:headers -Method Delete -ErrorAction Stop
            $successCount++
            Add-Content -Path $logFilePath -Value "[$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss zzz')] Mesajlar temizlendi: $queueName"
        } catch {
            $errorMsg = "Mesajlar temizlenemedi: $queueName - $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($errorMsg, "Hata", "OK", "Error")
            Add-Content -Path $logFilePath -Value "[$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss zzz')] $errorMsg"
            $failCount++
        }
    }

    Start-Sleep -Milliseconds 500
    $script:cachedQueues = $null
    Search-And-Display-Queues

    $msg = "İşlem tamamlandı. $successCount kuyruğun mesajları temizlendi."
    if ($failCount -gt 0) {
        $msg += " $failCount kuyrukta hata oluştu."
    }
    if ($zeroMessageCount -gt 0) {
        $msg += " $zeroMessageCount kuyrukta zaten mesaj yoktu."
    }
    [System.Windows.MessageBox]::Show($msg, "Bilgi", "OK", "Information")
}

# --- XAML Interface Definition ---
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="🐇 RabbitMQ Kuyruk Yöneticisi" Height="700" Width="1100" ResizeMode="CanResize" Background="#E6ECEF">
    <Window.Resources>
        <Style x:Key="HeaderButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#2C3E50"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="5,2"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="MinWidth" Value="80"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#4A90E2"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#357ABD"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Padding" Value="5"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#B0BEC5"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="Foreground" Value="#2C3E50"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="BorderBrush" Value="#B0BEC5"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="WhiteSmoke"/>
            <Setter Property="Padding" Value="5"/>
        </Style>
        <Style TargetType="TreeView">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="BorderBrush" Value="#B0BEC5"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="WhiteSmoke"/>
            <Setter Property="Padding" Value="5"/>
        </Style>
        <Style TargetType="TextBlock" x:Key="ListHeader">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#2C3E50"/>
            <Setter Property="Margin" Value="5,0,0,5"/>
        </Style>
        <Style TargetType="TextBlock" x:Key="StatusLabel">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Foreground" Value="#7F8C8D"/>
            <Setter Property="VerticalAlignment" Value="Bottom"/>
            <Setter Property="Margin" Value="20,0,0,0"/>
        </Style>
    </Window.Resources>
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="0,0,0,15">
            <TextBlock Text="🐇 RabbitMQ Kuyruk Yöneticisi" FontSize="24" FontWeight="SemiBold" Foreground="#2C3E50"/>
            <TextBlock Name="LastRefreshLabel" Style="{StaticResource StatusLabel}" Text="Son Yenileme: -"/>
            <TextBlock Name="QueueCountLabel" Style="{StaticResource StatusLabel}" Text="Kuyruk Adedi: 0"/>
        </StackPanel>
        <Grid Grid.Row="1" Margin="0,0,0,15">
            <StackPanel Orientation="Horizontal">
                <TextBox Name="SearchBox" Width="180" Height="32" Text="Kuyrukları ara..." Foreground="#7F8C8D" Padding="5" FontSize="14" BorderBrush="#B0BEC5" VerticalContentAlignment="Center"/>
                <CheckBox Name="RegexSearchCheckBox" Content="Regex" VerticalAlignment="Center" Foreground="#2C3E50" Margin="4,0"/>
                <Button Name="RefreshQueuesButton" Content="🔄 Yenile" Height="32" MinWidth="80" Background="#4A90E2" Padding="12,6"/>
                <Button Name="PurgeButton" Content="🧹 Temizle" Height="32" MinWidth="80" Background="#F39C12" Padding="12,6"/>
                <Button Name="DeleteButton" Content="🗑️ Sil" Height="32" MinWidth="80" Background="#E74C3C" Padding="12,6"/>
                <TextBox Name="GroupBox" Width="180" Height="32" Text="Grup ismi yaz..." Foreground="#7F8C8D" Padding="5" FontSize="14" BorderBrush="#B0BEC5" VerticalContentAlignment="Center"/>
                <Button Name="GroupButton" Content="📁 Grupla" Height="32" MinWidth="80" Background="#2ECC71" Padding="12,6"/>
                <Button Name="DeleteGroupButton" Content="❌ G. Sil" Height="32" MinWidth="80" Background="#E67E22" Padding="12,6"/>
                <Button Name="AddToGroupButton" Content="➕ G. Ekle" Height="32" MinWidth="80" Background="#3498DB" Padding="12,6"/>
                <Button Name="RemoveFromGroupButton" Content="➖ G. Çıkar" Height="32" MinWidth="80" Background="#9B59B6" Padding="12,6"/>
            </StackPanel>
        </Grid>
        <Grid Grid.Row="2" Margin="0,0,0,5">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="1*"/>
                <ColumnDefinition Width="1*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="1" Text="Kuyrukları Göster" Style="{StaticResource ListHeader}"/>
            <TextBlock Grid.Column="2" Text="Gruplar" Style="{StaticResource ListHeader}"/>
        </Grid>
        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="1*"/>
                <ColumnDefinition Width="1*"/>
            </Grid.ColumnDefinitions>
            <ListView Name="QueueListView" Grid.Column="0" FontSize="14" SelectionMode="Extended" BorderBrush="#B0BEC5" BorderThickness="1" Margin="0,0,10,0">
                <ListView.View>
                    <GridView>
                        <GridViewColumn Width="450">
                            <GridViewColumn.Header>
                                <Button Name="Header_Name" Style="{StaticResource HeaderButton}"/>
                            </GridViewColumn.Header>
                            <GridViewColumn.CellTemplate>
                                <DataTemplate>
                                    <TextBlock Text="{Binding Name}" ToolTip="{Binding Name}"/>
                                </DataTemplate>
                            </GridViewColumn.CellTemplate>
                        </GridViewColumn>
                        <GridViewColumn Width="150">
                            <GridViewColumn.Header>
                                <Button Name="Header_MessageCount" Style="{StaticResource HeaderButton}"/>
                            </GridViewColumn.Header>
                            <GridViewColumn.CellTemplate>
                                <DataTemplate>
                                    <TextBlock Text="{Binding MessageCount}" HorizontalAlignment="Right" Margin="0,0,10,0"/>
                                </DataTemplate>
                            </GridViewColumn.CellTemplate>
                        </GridViewColumn>
                    </GridView>
                </ListView.View>
            </ListView>
            <ListBox Name="QueueDisplayListBox" Grid.Column="1" FontSize="13" BorderBrush="#B0BEC5" BorderThickness="1" Background="WhiteSmoke" Padding="5" Margin="0,0,10,0"/>
            <TreeView Name="GroupedTreeView" Grid.Column="2" FontSize="13" BorderBrush="#B0BEC5" BorderThickness="1" Background="WhiteSmoke" Padding="5"/>
        </Grid>
    </Grid>
</Window>
"@

# --- Control and Event Assignments ---
try {
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Error "XAML yüklenirken hata oluştu: $($_.Exception.Message)"
    exit
}

$SearchBox = $window.FindName("SearchBox")
$RegexSearchCheckBox = $window.FindName("RegexSearchCheckBox")
$QueueListView = $window.FindName("QueueListView")
$RefreshQueuesButton = $window.FindName("RefreshQueuesButton")
$LastRefreshLabel = $window.FindName("LastRefreshLabel")
$QueueCountLabel = $window.FindName("QueueCountLabel")
$Header_Name = $window.FindName("Header_Name")
$Header_MessageCount = $window.FindName("Header_MessageCount")
$PurgeButton = $window.FindName("PurgeButton")
$DeleteButton = $window.FindName("DeleteButton")
$QueueDisplayListBox = $window.FindName("QueueDisplayListBox")
$GroupBox = $window.FindName("GroupBox")
$GroupButton = $window.FindName("GroupButton")
$DeleteGroupButton = $window.FindName("DeleteGroupButton")
$AddToGroupButton = $window.FindName("AddToGroupButton")
$RemoveFromGroupButton = $window.FindName("RemoveFromGroupButton")
$GroupedTreeView = $window.FindName("GroupedTreeView")

# Events
$script:searchTimer.Add_Tick({ $script:searchTimer.Stop(); Search-And-Display-Queues })
$SearchBox.Add_TextChanged({ $script:searchTimer.Stop(); $script:searchTimer.Start() })
$RegexSearchCheckBox.Add_Checked({ Search-And-Display-Queues })
$RegexSearchCheckBox.Add_Unchecked({ Search-And-Display-Queues })
$RefreshQueuesButton.Add_Click({ $script:cachedQueues = $null; Search-And-Display-Queues })
$GroupButton.Add_Click({ Group-SelectedQueues })
$DeleteButton.Add_Click({ Delete-SelectedQueues })
$DeleteGroupButton.Add_Click({ Delete-SelectedGroup })
$AddToGroupButton.Add_Click({ Add-QueueToSelectedGroup })
$RemoveFromGroupButton.Add_Click({ Remove-QueueFromSelectedGroup })
$PurgeButton.Add_Click({ Purge-SelectedQueuesMessages })
$QueueListView.Add_SelectionChanged({ Refresh-QueueDisplayListBox })
$Header_Name.Add_Click({ 
    if ($script:sortColumn -eq "Name") { 
        $script:sortDirection = if ($script:sortDirection -eq "Ascending") { "Descending" } else { "Ascending" } 
    } else { 
        $script:sortColumn = "Name"; $script:sortDirection = "Ascending" 
    }; 
    Search-And-Display-Queues 
})
$Header_MessageCount.Add_Click({ 
    if ($script:sortColumn -eq "MessageCount") { 
        $script:sortDirection = if ($script:sortDirection -eq "Ascending") { "Descending" } else { "Ascending" } 
    } else { 
        $script:sortColumn = "MessageCount"; $script:sortDirection = "Descending" 
    }; 
    Search-And-Display-Queues 
})

# Placeholder Behaviors
$SearchBox.Add_GotFocus({ if ($SearchBox.Text -eq "Kuyrukları ara...") { $SearchBox.Text = ""; $SearchBox.Foreground = "#2C3E50" } })
$SearchBox.Add_LostFocus({ if ([string]::IsNullOrWhiteSpace($SearchBox.Text)) { $SearchBox.Text = "Kuyrukları ara..."; $SearchBox.Foreground = "#7F8C8D" } })
$GroupBox.Add_GotFocus({ if ($GroupBox.Text -eq "Grup ismi yaz...") { $GroupBox.Text = ""; $GroupBox.Foreground = "#2C3E50" } })
$GroupBox.Add_LostFocus({ if ([string]::IsNullOrWhiteSpace($GroupBox.Text)) { $GroupBox.Text = "Grup ismi yaz..."; $GroupBox.Foreground = "#7F8C8D" } })

# --- Initialization ---
$window.Title = "🐇 RabbitMQ Kuyruk Yöneticisi ($script:Environment)"

userEntrance
Set-AuthHeader
Load-Groups
Update-SortIndicators
$QueueDisplayListBox.Items.Add("Detay için kuyruk seçin.")
Search-And-Display-Queues

# --- Show Window ---
$window.ShowDialog() | Out-Null