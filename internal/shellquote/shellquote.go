package shellquote

import "strings"

func Word(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func Command(arguments []string) string {
	quoted := make([]string, len(arguments))
	for index, argument := range arguments {
		quoted[index] = Word(argument)
	}
	return strings.Join(quoted, " ")
}
