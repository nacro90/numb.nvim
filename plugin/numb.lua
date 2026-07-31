if vim.g.loaded_numb then
  return
end
vim.g.loaded_numb = 1

require("numb").setup()
