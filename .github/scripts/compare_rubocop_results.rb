require 'json'

baseline_path, head_path, *changed_files = ARGV
abort 'Expected baseline report, head report, and changed files' if changed_files.empty?

def offense_counts(report_path, changed_files)
  report = JSON.parse(File.read(report_path))
  counts = Hash.new(0)

  report.fetch('files').each do |file|
    path = file.fetch('path').tr('\\', '/')
    relative_path = changed_files.find { |candidate| path == candidate || path.end_with?("/#{candidate}") }
    next unless relative_path

    file.fetch('offenses').each do |offense|
      counts[[relative_path, offense.fetch('cop_name')]] += 1
    end
  end
  counts
end

baseline = offense_counts(baseline_path, changed_files)
head = offense_counts(head_path, changed_files)
head_report = JSON.parse(File.read(head_path))
new_offenses = head.filter_map do |key, count|
  increase = count - baseline[key]
  next unless increase.positive?

  file = head_report.fetch('files').find do |entry|
    path = entry.fetch('path').tr('\\', '/')
    path == key[0] || path.end_with?("/#{key[0]}")
  end
  lines = file.fetch('offenses').filter_map do |offense|
    offense.dig('location', 'start_line') if offense.fetch('cop_name') == key[1]
  end
  "#{key[0]}: #{key[1]} gained #{increase} offense(s) (lines: #{lines.join(', ')})"
end

abort new_offenses.join("\n") if new_offenses.any?

puts 'RuboCop: no new offenses in changed Ruby files.'
